#include "pf_window.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_text.h"
#include "pf_utf8.h"

/* Characters shaped per line: far more than fit on any screen, bounding the cost of a very
 * long line. Bracket matching looks at most PAREN_SCAN characters away from point. */
enum { MAX_SHAPED_CHARS = 4096, PAREN_SCAN = 100000 };

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
    int line_numbers, hl_line, show_paren;
    uint32_t *scan; /* decoded characters for bracket matching */
    size_t scan_cap;
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
        free(w->scan);
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

int pf_window_set_option(pf_window *w, pf_window_option option, int on) {
    int *slot = option == PF_WINDOW_LINE_NUMBERS ? &w->line_numbers
                : option == PF_WINDOW_HL_LINE    ? &w->hl_line
                : option == PF_WINDOW_SHOW_PAREN ? &w->show_paren
                                                 : NULL;
    if (!slot) {
        return -1;
    }
    *slot = on != 0;
    w->dirty = 1;
    return 0;
}

int pf_window_option_value(const pf_window *w, pf_window_option option) {
    return option == PF_WINDOW_LINE_NUMBERS ? w->line_numbers
           : option == PF_WINDOW_HL_LINE    ? w->hl_line
           : option == PF_WINDOW_SHOW_PAREN ? w->show_paren
                                            : -1;
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

/* Decodes characters [START, END) of S into *OUT (grown as needed; raw bytes as U+FFFD). */
static size_t decode_range(pf_window *w, const pf_text_snapshot *s, size_t start, size_t end,
                           uint32_t **out, size_t *cap) {
    size_t n = end - start;
    size_t nbytes = pf_text_copy(s, start, end, NULL, 0);
    if (nbytes > w->bytes_cap) {
        w->bytes_cap = nbytes * 2;
        w->bytes = xrealloc(w->bytes, w->bytes_cap);
    }
    if (n > *cap) {
        *cap = n * 2;
        *out = xrealloc(*out, *cap * sizeof **out);
    }
    uint32_t *cps = *out;
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
        cps[k++] = cp;
        i += u;
    }
    return k;
}

static size_t load_line(pf_window *w, const pf_text_snapshot *s, size_t start, size_t end) {
    if (end - start > MAX_SHAPED_CHARS) {
        end = start + MAX_SHAPED_CHARS;
    }
    return decode_range(w, s, start, end, &w->cps, &w->cps_cap);
}

/* ---- show-paren ---- */

static uint32_t closer_of(uint32_t c) {
    return c == '(' ? ')' : c == '[' ? ']' : c == '{' ? '}' : 0;
}

static uint32_t opener_of(uint32_t c) {
    return c == ')' ? '(' : c == ']' ? '[' : c == '}' ? '{' : 0;
}

typedef struct paren_match {
    int active, found, mismatch;
    size_t at, other; /* the bracket at point and its partner (if found) */
} paren_match;

/* Emacs show-paren: a bracket opening after point or closing before it, and its partner.
 * Plain bracket counting for now; strings and comments need syntax (M5, tree-sitter). */
static paren_match find_paren(pf_window *w, const pf_text_snapshot *s, size_t point) {
    paren_match m = {0};
    size_t chars = pf_text_chars(s);
    uint32_t c;
    if (point < chars && decode_range(w, s, point, point + 1, &w->scan, &w->scan_cap) == 1 &&
        closer_of(c = w->scan[0])) {
        size_t end = chars - point > PAREN_SCAN ? point + PAREN_SCAN : chars;
        size_t n = decode_range(w, s, point, end, &w->scan, &w->scan_cap);
        m.active = 1;
        m.at = point;
        long depth = 0;
        for (size_t i = 0; i < n; i++) {
            uint32_t x = w->scan[i];
            depth += closer_of(x) ? 1 : opener_of(x) ? -1 : 0;
            if (depth == 0) {
                m.found = 1;
                m.other = point + i;
                m.mismatch = x != closer_of(c);
                return m;
            }
        }
        m.mismatch = 1;
        return m;
    }
    if (point > 0 && decode_range(w, s, point - 1, point, &w->scan, &w->scan_cap) == 1 &&
        opener_of(c = w->scan[0])) {
        size_t begin = point > PAREN_SCAN ? point - PAREN_SCAN : 0;
        size_t n = decode_range(w, s, begin, point, &w->scan, &w->scan_cap);
        m.active = 1;
        m.at = point - 1;
        long depth = 0;
        for (size_t i = n; i-- > 0;) {
            uint32_t x = w->scan[i];
            depth += opener_of(x) ? 1 : closer_of(x) ? -1 : 0;
            if (depth == 0) {
                m.found = 1;
                m.other = begin + i;
                m.mismatch = x != opener_of(c);
                return m;
            }
        }
        m.mismatch = 1;
    }
    return m;
}

static size_t count_digits(size_t n) {
    size_t d = 1;
    while (n >= 10) {
        n /= 10;
        d++;
    }
    return d;
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
    size_t point_line = pf_text_line_of(s, point);
    paren_match paren = w->show_paren ? find_paren(w, s, point) : (paren_match){0};
    /* Gutter sized for the buffer's last line number, one cell of padding on each side. */
    size_t digits = count_digits(lines);
    float gutter = w->line_numbers ? (float)(digits + 2) * st->cell_width : 0;
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
        float x0 = st->pad_left + gutter;

        /* Backgrounds first: hl-line band, then bracket highlights on this line. */
        if (w->hl_line && line == point_line) {
            pf_display_rect(d, x0, top, right - x0, st->line_height, st->hl_line);
        }
        if (paren.active) {
            size_t marks[2] = {paren.at, paren.other};
            for (int m = 0; m < (paren.found ? 2 : 1); m++) {
                if (marks[m] < start || marks[m] >= end) {
                    continue;
                }
                size_t idx = marks[m] - start;
                if (pre && idx >= k) {
                    idx += pre; /* after the spliced-in composition */
                }
                if (idx < lay->nchars) {
                    float px = lay->caret_x[idx], pw = lay->caret_x[idx + 1] - px;
                    pf_display_rect(d, x0 + px, top, pw, st->line_height,
                                    paren.mismatch ? st->paren_mismatch : st->paren_match);
                }
            }
        }
        if (w->line_numbers) {
            char num[24];
            int len = snprintf(num, sizeof num, "%zu", line + 1);
            uint32_t ncps[24];
            for (int i = 0; i < len; i++) {
                ncps[i] = (uint32_t)num[i];
            }
            const pf_line_layout *nl = pf_layout_line(w->cache, st->font, ncps, (size_t)len);
            float nx = st->pad_left + gutter - st->cell_width - nl->width; /* right-aligned */
            emit_glyphs(d, nl, nx, baseline, right,
                        line == point_line ? st->line_number_current : st->line_number, 0,
                        (size_t)-1);
        }
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
