#include "pf_window.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_text.h"
#include "pf_utf8.h"

/* Characters shaped per line: far more than fit on any screen, bounding the cost of a very
 * long line. */
enum { MAX_SHAPED_CHARS = 4096 };

struct pf_window {
    pf_layout_cache *cache;
    pf_window_style style;
    pf_handle buf;
    uint32_t point_marker;
    float width, height, scale;
    size_t top;
    int dirty;
    /* What the last frame showed; the snapshot is retained so its address stays unique. */
    const pf_text_snapshot *shown;
    size_t shown_point, shown_top;
    char *bytes;
    size_t bytes_cap;
    uint32_t *cps;
    size_t cps_cap;
    /* Input-method composition shown at point but not in the buffer. */
    uint32_t *preedit;
    size_t preedit_len, preedit_caret;
    float cursor[4]; /* last frame's cursor rect: x, y, w, h */
    int cursor_valid;
};

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size ? size : 1);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

pf_window *pf_window_new(pf_layout_cache *cache, const pf_window_style *style) {
    pf_window *w = xrealloc(NULL, sizeof *w);
    memset(w, 0, sizeof *w);
    w->cache = cache;
    w->style = *style;
    w->scale = 1;
    w->dirty = 1;
    return w;
}

void pf_window_free(pf_window *w) {
    if (w) {
        pf_text_snapshot_release(w->shown);
        free(w->bytes);
        free(w->cps);
        free(w->preedit);
        free(w);
    }
}

void pf_window_set_buffer(pf_window *w, pf_handle buf, uint32_t point) {
    if (buf != w->buf) {
        w->top = 0;
    }
    w->buf = buf;
    w->point_marker = point;
    w->dirty = 1;
}

void pf_window_set_size(pf_window *w, float width, float height, float scale) {
    if (width != w->width || height != w->height || scale != w->scale) {
        w->width = width;
        w->height = height;
        w->scale = scale;
        w->dirty = 1;
    }
}

void pf_window_set_style(pf_window *w, const pf_window_style *style) {
    w->style = *style;
    w->dirty = 1;
}

void pf_window_set_preedit(pf_window *w, const uint32_t *cps, size_t n, size_t caret) {
    w->preedit = xrealloc(w->preedit, (n ? n : 1) * sizeof *w->preedit);
    if (n) {
        memcpy(w->preedit, cps, n * sizeof *cps);
    }
    w->preedit_len = n;
    w->preedit_caret = caret < n ? caret : n;
    w->dirty = 1;
}

int pf_window_cursor_rect(const pf_window *w, float rect[4]) {
    if (!w->cursor_valid) {
        return -1;
    }
    memcpy(rect, w->cursor, sizeof w->cursor);
    return 0;
}

void pf_window_invalidate(pf_window *w) {
    w->dirty = 1;
}

size_t pf_window_top_line(const pf_window *w) {
    return w->top;
}

size_t pf_window_body_lines(const pf_window *w) {
    float lh = w->style.line_height;
    float usable = w->height - w->style.pad_top;
    size_t n = lh > 0 && usable > 0 ? (size_t)floorf(usable / lh) : 0;
    return n ? n : 1;
}

/* Scrolls minimally so the line holding POS is fully visible. */
static void keep_visible(pf_window *w, const pf_text_snapshot *s, size_t pos) {
    size_t line = pf_text_line_of(s, pos), body = pf_window_body_lines(w);
    if (line < w->top) {
        w->top = line;
    } else if (line >= w->top + body) {
        w->top = line - body + 1;
    }
    size_t last = pf_text_lines(s) - 1;
    if (w->top > last) {
        w->top = last;
    }
}

/* Decodes characters [START, END) of S into w->cps (raw bytes as U+FFFD). */
static size_t load_line(pf_window *w, const pf_text_snapshot *s, size_t start, size_t end) {
    size_t n = end - start;
    if (n > MAX_SHAPED_CHARS) {
        n = MAX_SHAPED_CHARS;
        end = start + n;
    }
    size_t nbytes = pf_text_copy(s, start, end, NULL, 0);
    if (nbytes > w->bytes_cap) {
        w->bytes_cap = nbytes * 2;
        w->bytes = xrealloc(w->bytes, w->bytes_cap);
    }
    if (n > w->cps_cap) {
        w->cps_cap = n * 2;
        w->cps = xrealloc(w->cps, w->cps_cap * sizeof *w->cps);
    }
    pf_text_copy(s, start, end, w->bytes, nbytes);
    const unsigned char *p = (const unsigned char *)w->bytes;
    size_t i = 0, k = 0;
    while (i < nbytes && k < n) {
        size_t u = pf_utf8_unit_len(p + i, nbytes - i);
        uint32_t cp;
        if (u == 1) {
            cp = p[i] < 0x80 ? p[i] : 0xFFFD;
        } else {
            cp = p[i] & (0x7F >> u);
            for (size_t j = 1; j < u; j++) {
                cp = cp << 6 | (p[i + j] & 0x3F);
            }
        }
        w->cps[k++] = cp;
        i += u;
    }
    return k;
}

static void emit_glyphs(pf_display *d, const pf_line_layout *lay, float x0, float baseline,
                        float right, uint32_t color, size_t from_char, size_t to_char) {
    for (size_t g = 0; g < lay->nglyphs; g++) {
        const pf_shaped_glyph *sg = &lay->glyphs[g];
        if (sg->cluster < from_char || sg->cluster >= to_char) {
            continue;
        }
        float x = x0 + sg->x;
        if (x > right) {
            continue; /* truncated at the window edge */
        }
        pf_display_glyph(d, sg->font, sg->glyph, x, baseline, color);
    }
}

const pf_display *pf_window_redisplay(pf_window *w) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    size_t point = 0;
    if (text) {
        point = pf_marker_pos(text, w->point_marker);
        if (point == SIZE_MAX) {
            point = 0;
        }
        keep_visible(w, s, point);
    }
    if (!w->dirty && s == w->shown && point == w->shown_point && w->top == w->shown_top) {
        return NULL;
    }
    w->dirty = 0;
    pf_text_snapshot_release(w->shown);
    w->shown = s ? pf_text_snapshot_retain(s) : NULL;
    w->shown_point = point;
    w->shown_top = w->top;

    const pf_window_style *st = &w->style;
    pf_display *d = pf_display_new(w->width, w->height, w->scale, st->background);
    w->cursor_valid = 0;
    if (!s) {
        return pf_display_finish(d);
    }
    pf_layout_begin_frame(w->cache);
    size_t lines = pf_text_lines(s), chars = pf_text_chars(s);
    size_t visible = st->line_height > 0 ? (size_t)ceilf(w->height / st->line_height) + 1 : 1;
    float right = w->width;
    for (size_t row = 0; row < visible && w->top + row < lines; row++) {
        size_t line = w->top + row;
        size_t start = pf_text_line_start(s, line);
        size_t next = pf_text_line_start(s, line + 1);
        size_t end = next > start && next <= chars && line + 1 < lines ? next - 1 : next;
        size_t n = load_line(w, s, start, end);
        int here = point >= start && point <= end;
        size_t k = here ? point - start : 0, pre = here ? w->preedit_len : 0;
        if (pre && k <= n) {
            /* Splice the composition in at point, as the input method shows it. */
            if (n + pre > w->cps_cap) {
                w->cps_cap = (n + pre) * 2;
                w->cps = xrealloc(w->cps, w->cps_cap * sizeof *w->cps);
            }
            memmove(w->cps + k + pre, w->cps + k, (n - k) * sizeof *w->cps);
            memcpy(w->cps + k, w->preedit, pre * sizeof *w->cps);
            n += pre;
        }
        const pf_line_layout *lay = pf_layout_line(w->cache, st->font, w->cps, n);
        float top = st->pad_top + (float)row * st->line_height;
        float baseline = top + st->ascent;
        float x0 = st->pad_left;
        emit_glyphs(d, lay, x0, baseline, right, st->foreground, 0, (size_t)-1);

        if (here) {
            if (pre) {
                float ux = lay->caret_x[k], uw = lay->caret_x[k + pre] - ux;
                pf_display_rect(d, x0 + ux, baseline + st->descent * 0.5f, uw, 1.0f / w->scale,
                                st->foreground); /* one device pixel */
                k += w->preedit_caret;
            }
            /* Filled box cursor; the character under it is redrawn in the background color. */
            float cx = k <= lay->nchars ? lay->caret_x[k] : lay->width;
            float cw = k < lay->nchars ? lay->caret_x[k + 1] - cx : st->cell_width;
            if (cw <= 0) {
                cw = st->cell_width;
            }
            pf_display_rect(d, x0 + cx, top, cw, st->line_height, st->cursor);
            w->cursor[0] = x0 + cx;
            w->cursor[1] = top;
            w->cursor[2] = cw;
            w->cursor[3] = st->line_height;
            w->cursor_valid = 1;
            if (k < lay->nchars) {
                emit_glyphs(d, lay, x0, baseline, right, st->background, k, k + 1);
            }
        }
    }
    return pf_display_finish(d);
}
