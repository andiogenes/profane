#include "pf_window.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_face.h"
#include "pf_props.h"
#include "pf_text.h"
#include "pf_utf8.h"

/* Characters shaped per line: far more than fit on any screen, bounding the cost of a very
 * long line. Bracket matching looks at most PAREN_SCAN characters away from point. */
enum { MAX_SHAPED_CHARS = 4096, PAREN_SCAN = 100000 };

/* Emacs's hscroll-margin: cells kept between point and either edge before scrolling sideways. */
enum { HSCROLL_MARGIN = 5 };

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
    uint32_t *fids; /* face id of each character of the line being drawn */
    size_t fids_cap;
    pf_font_run *runs;
    size_t runs_cap;
    pf_prop_run *props_buf;
    size_t props_cap;
    uint64_t shown_faces, shown_props; /* generations drawn by the last frame */
    int cursor_kind; /* PF_CURSOR_* */
    const pf_font_source *fonts;
    float text_scale;
    uint32_t scaled_from[32], scaled_to[32]; /* font -> its text-scaled copy */
    size_t nscaled;
    float fringe_left, fringe_right, divider;
    pf_strip mode_line;
    float mode_line_h;
    size_t region_start, region_end; /* the active region, empty: none */
    uint32_t native; /* native view kind, 0: text */
    pf_canvas *canvas; /* canvas window: drawn instead of text */
    uint64_t shown_canvas_version;
    const pf_canvas *shown_canvas;
    float hscroll, min_hscroll; /* points the text is scrolled left; scroll-left's minimum */
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
    w->cursor_kind = PF_CURSOR_BOX;
    w->text_scale = 1;
    return w;
}

void pf_window_free(pf_window *w) {
    if (w) {
        pf_text_snapshot_release(w->shown);
        free(w->bytes);
        free(w->cps);
        free(w->preedit);
        free(w->scan);
        free(w->fids);
        free(w->runs);
        free(w->props_buf);
        pf_strip_free(&w->mode_line);
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

/* The font a face's characters are drawn in: its own or the default, text-scaled. */
static uint32_t default_font_of(const pf_window *w) {
    uint32_t f = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT))->font;
    return f ? f : w->style.font;
}

static void update_mode_line_height(pf_window *w) {
    w->mode_line_h = w->mode_line.face ? pf_strip_height(w->fonts, w->mode_line.face,
                                                         default_font_of(w), w->mode_line.box)
                                       : 0;
}

void pf_window_set_style(pf_window *w, const pf_window_style *style) {
    w->style = *style;
    update_mode_line_height(w); /* faces may have changed too */
    w->dirty = 1;
}

void pf_window_set_fonts(pf_window *w, const pf_font_source *fonts) {
    w->fonts = fonts;
    w->nscaled = 0;
    update_mode_line_height(w);
    w->dirty = 1;
}

void pf_window_set_text_scale(pf_window *w, float factor) {
    if (factor > 0 && factor != w->text_scale) {
        w->text_scale = factor;
        w->nscaled = 0;
        w->dirty = 1;
    }
}

static uint32_t scaled_font(pf_window *w, uint32_t font) {
    if (w->text_scale == 1.0f) {
        return font;
    }
    for (size_t i = 0; i < w->nscaled; i++) {
        if (w->scaled_from[i] == font) {
            return w->scaled_to[i];
        }
    }
    if (w->nscaled == sizeof w->scaled_from / sizeof *w->scaled_from) {
        w->nscaled = 0;
    }
    uint32_t to = pf_font_source_scaled(w->fonts, font, w->text_scale);
    w->scaled_from[w->nscaled] = font;
    w->scaled_to[w->nscaled++] = to;
    return to;
}

void pf_window_set_edges(pf_window *w, float fringe_left, float fringe_right, float divider) {
    if (fringe_left != w->fringe_left || fringe_right != w->fringe_right ||
        divider != w->divider) {
        w->fringe_left = fringe_left;
        w->fringe_right = fringe_right;
        w->divider = divider;
        w->dirty = 1;
    }
}

void pf_window_set_mode_line(pf_window *w, const uint32_t *cps, size_t n,
                             const pf_strip_run *runs, size_t nruns, uint32_t face, int box) {
    if (pf_strip_set(&w->mode_line, cps, n, runs, nruns, face, box)) {
        update_mode_line_height(w);
        w->dirty = 1;
    }
}

float pf_window_mode_line_height(const pf_window *w) {
    return w->mode_line_h;
}

float pf_window_hscroll(const pf_window *w) {
    return w->hscroll;
}

void pf_window_set_min_hscroll(pf_window *w, float points) {
    w->min_hscroll = points > 0 ? points : 0;
    w->dirty = 1;
}

void pf_window_set_top_line(pf_window *w, size_t line) {
    w->top = line;
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
    if (option == PF_WINDOW_CURSOR) {
        w->cursor_kind = on;
        w->dirty = 1;
        return 0;
    }
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
           : option == PF_WINDOW_CURSOR     ? w->cursor_kind
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
    float usable = w->height - w->mode_line_h - w->style.pad_top;
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

/* Color of role ROLE's face, attribute FLAG (PF_FACE_HAS_FG/BG), or FALLBACK. */
static uint32_t role_color(pf_face_role role, uint32_t flag, uint32_t fallback) {
    const pf_face *f = pf_face_get(pf_face_role_id(role));
    if (!(f->flags & flag)) {
        return fallback;
    }
    return flag == PF_FACE_HAS_FG ? f->fg : f->bg;
}

static uint32_t face_fg(uint32_t id, uint32_t fallback) {
    const pf_face *f = pf_face_get(id);
    return f->flags & PF_FACE_HAS_FG ? f->fg : fallback;
}

/* Glyphs of LAY with clusters in [FROM, TO). Each takes its character's face color (FIDS) or
 * COLOR when FIDS is NULL / the face sets none. */
static void emit_glyphs(pf_display *d, const pf_line_layout *lay, float x0, float baseline,
                        float left, float right, uint32_t color, const uint32_t *fids,
                        size_t from_char, size_t to_char) {
    for (size_t g = 0; g < lay->nglyphs; g++) {
        const pf_shaped_glyph *sg = &lay->glyphs[g];
        if (sg->cluster < from_char || sg->cluster >= to_char) {
            continue;
        }
        size_t k = sg->cluster < lay->nchars ? sg->cluster : lay->nchars - 1;
        if (lay->nchars && (x0 + lay->caret_x[k + 1] > right + 0.5f ||
                            x0 + lay->caret_x[k] < left - 0.5f)) {
            continue; /* would cross an edge: truncated, or scrolled out on the left */
        }
        float x = x0 + sg->x;
        uint32_t c = fids && sg->cluster < lay->nchars ? face_fg(fids[sg->cluster], color) : color;
        pf_display_glyph(d, sg->font, sg->glyph, x, baseline, c);
    }
}

/* Background and underline rects for runs of characters whose face sets them. */
static void emit_face_decorations(pf_display *d, const pf_line_layout *lay, const uint32_t *fids,
                                  float x0, float left, float right, float top, float baseline,
                                  const pf_window_style *st, float scale, uint32_t default_fg) {
    size_t n = lay->nchars;
    uint32_t def = pf_face_role_id(PF_ROLE_DEFAULT);
    for (size_t i = 0; i < n;) {
        size_t j = i + 1;
        while (j < n && fids[j] == fids[i]) {
            j++;
        }
        if (fids[i] == def) {
            i = j; /* the default background is the clear color: nothing to draw */
            continue;
        }
        const pf_face *f = pf_face_get(fids[i]);
        float x = fmaxf(x0 + lay->caret_x[i], left);
        float wdt = fminf(x0 + lay->caret_x[j], right) - x;
        if (f->flags & PF_FACE_HAS_BG) {
            pf_display_rect(d, x, top, wdt, st->line_height, f->bg);
        }
        if (f->flags & PF_FACE_UNDERLINE) {
            uint32_t uc = f->underline_color ? f->underline_color
                                             : (f->flags & PF_FACE_HAS_FG ? f->fg : default_fg);
            pf_display_rect(d, x, baseline + st->descent * 0.4f, wdt, 1.0f / scale, uc);
        }
        i = j;
    }
}

static void *grow(void *p, size_t *cap, size_t need, size_t elem) {
    if (need > *cap) {
        *cap = need * 2;
        p = xrealloc(p, *cap * elem);
    }
    return p;
}

/* Face id of every character of the line [START, START+N) (text property PF_PROP_FACE), with
 * PRE default-face characters spliced in at K for an input-method composition. */
static void load_faces(pf_window *w, pf_text *text, size_t start, size_t n, size_t k, size_t pre) {
    w->fids = grow(w->fids, &w->fids_cap, n + pre + 1, sizeof *w->fids);
    uint32_t def = pf_face_role_id(PF_ROLE_DEFAULT);
    for (size_t i = 0; i < n + pre; i++) {
        w->fids[i] = def;
    }
    size_t total = pf_props_runs(pf_text_props(text), PF_PROP_FACE, start, start + n, NULL, 0);
    w->props_buf = grow(w->props_buf, &w->props_cap, total + 1, sizeof *w->props_buf);
    pf_props_runs(pf_text_props(text), PF_PROP_FACE, start, start + n, w->props_buf, total);
    for (size_t r = 0; r < total; r++) {
        for (size_t p = w->props_buf[r].start; p < w->props_buf[r].end; p++) {
            size_t idx = p - start;
            w->fids[pre && idx >= k ? idx + pre : idx] = w->props_buf[r].value;
        }
    }
}

/* Font runs for N characters with faces FIDS: a face without a font uses DEFAULT_FONT. */
static size_t font_runs(pf_window *w, size_t n, uint32_t default_font) {
    w->runs = grow(w->runs, &w->runs_cap, n + 1, sizeof *w->runs);
    size_t nruns = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t f = pf_face_get(w->fids[i])->font;
        f = f ? scaled_font(w, f) : default_font;
        if (nruns && w->runs[nruns - 1].font == f) {
            w->runs[nruns - 1].len++;
        } else {
            w->runs[nruns++] = (pf_font_run){i, 1, f};
        }
    }
    return nruns;
}

/* A buffer line laid out for drawing: its range, and where point and the input-method
 * composition sit in it. */
typedef struct row {
    size_t start, end;   /* characters of the line, without its newline */
    int here;            /* point is on it */
    size_t k, pre;       /* point's index in the laid-out line; composition length spliced at k */
    const pf_line_layout *lay;
} row;

/* Lays out LINE with faces (w->fids) and, if point is on it, the composition spliced in. */
static row layout_row(pf_window *w, pf_text *text, const pf_text_snapshot *s, size_t line,
                      size_t point, uint32_t default_font) {
    row r = {0};
    size_t lines = pf_text_lines(s), chars = pf_text_chars(s);
    r.start = pf_text_line_start(s, line);
    size_t next = pf_text_line_start(s, line + 1);
    r.end = next > r.start && next <= chars && line + 1 < lines ? next - 1 : next;
    size_t n = load_line(w, s, r.start, r.end);
    size_t nline = n;
    r.here = point >= r.start && point <= r.end;
    r.k = r.here ? point - r.start : 0;
    r.pre = r.here ? w->preedit_len : 0;
    if (r.pre && r.k <= n) {
        /* Splice the composition in at point, as the input method shows it. */
        w->cps = grow(w->cps, &w->cps_cap, n + r.pre, sizeof *w->cps);
        memmove(w->cps + r.k + r.pre, w->cps + r.k, (n - r.k) * sizeof *w->cps);
        memcpy(w->cps + r.k, w->preedit, r.pre * sizeof *w->cps);
        n += r.pre;
    } else {
        r.pre = 0;
    }
    load_faces(w, text, r.start, nline, r.k, r.pre);
    size_t nruns = font_runs(w, n, default_font);
    r.lay = pf_layout_line_runs(w->cache, w->runs, nruns, w->cps, n);
    return r;
}

/* Where the cursor goes in R (x relative to the line start) and its width. */
static void cursor_span(const pf_window *w, const row *r, float *cx, float *cw) {
    const pf_line_layout *lay = r->lay;
    size_t k = r->k + (r->pre ? w->preedit_caret : 0);
    *cx = k <= lay->nchars ? lay->caret_x[k] : lay->width;
    *cw = k < lay->nchars ? lay->caret_x[k + 1] - *cx : w->style.cell_width;
    if (*cw <= 0) {
        *cw = w->style.cell_width;
    }
}

/* Emacs auto-hscroll: if the cursor at CX..CX+CW is not within the text area of width WIDTH
 * (keeping a margin), scroll so it is centered, in whole cells, never below min_hscroll. */
static void auto_hscroll(pf_window *w, float cx, float cw, float width) {
    float cell = w->style.cell_width > 0 ? w->style.cell_width : 1;
    float margin = fminf(HSCROLL_MARGIN * cell, width / 4);
    float h = fmaxf(w->hscroll, w->min_hscroll);
    if ((cx < h + margin && h > w->min_hscroll) || cx + cw > h + width - margin) {
        h = floorf((cx - width / 2) / cell) * cell;
    }
    w->hscroll = fmaxf(fmaxf(h, 0), w->min_hscroll);
}

/* The buffer's visible lines: faces, hl-line, brackets, line numbers, text, cursor, and marks in
 * the fringes for lines continuing past the edges. */
static void draw_text(pf_window *w, pf_display *d, pf_text *text, const pf_text_snapshot *s,
                      size_t point, uint32_t bg, uint32_t fg) {
    const pf_window_style *st = &w->style;
    uint32_t default_font = scaled_font(w, default_font_of(w));
    size_t lines = pf_text_lines(s);
    /* A partly visible last row is drawn only where the mode line, drawn later, covers its
     * overflow. */
    float body_h = w->height - w->mode_line_h - st->pad_top;
    size_t visible = !w->mode_line.face           ? pf_window_body_lines(w)
                     : st->line_height > 0 && body_h > 0 ? (size_t)ceilf(body_h / st->line_height)
                                                       : 0;
    float right = w->width - w->divider - w->fringe_right;
    size_t point_line = pf_text_line_of(s, point);
    paren_match paren = w->show_paren ? find_paren(w, s, point) : (paren_match){0};
    /* Gutter sized for the buffer's last line number, one cell of padding on each side. */
    size_t digits = count_digits(lines);
    float gutter = w->line_numbers ? (float)(digits + 2) * st->cell_width : 0;
    float left = st->pad_left + w->fringe_left + gutter; /* the text area: left .. right */
    if (point_line >= w->top && point_line < w->top + visible) {
        row r = layout_row(w, text, s, point_line, point, default_font);
        float cx, cw;
        cursor_span(w, &r, &cx, &cw);
        auto_hscroll(w, cx, cw, right - left);
    } else {
        w->hscroll = fmaxf(w->hscroll, w->min_hscroll);
    }
    float x0 = left - w->hscroll; /* where line starts are drawn */
    uint32_t mark = role_color(PF_ROLE_FRINGE, PF_FACE_HAS_FG,
                               role_color(PF_ROLE_LINE_NUMBER, PF_FACE_HAS_FG, fg));

    for (size_t i = 0; i < visible && w->top + i < lines; i++) {
        size_t line = w->top + i;
        row r = layout_row(w, text, s, line, point, default_font);
        const pf_line_layout *lay = r.lay;
        float top = st->pad_top + (float)i * st->line_height;
        float baseline = top + st->ascent;

        /* Backgrounds first: faces, the hl-line band (an overlay in Emacs, so above them), then
         * bracket highlights. */
        emit_face_decorations(d, lay, w->fids, x0, left, right, top, baseline, st, w->scale, fg);
        if (w->hl_line && line == point_line) {
            pf_display_rect(d, left, top, right - left, st->line_height,
                            role_color(PF_ROLE_HL_LINE, PF_FACE_HAS_BG, 0));
        }
        if (w->region_end > r.start && w->region_start <= r.end && w->region_start != w->region_end) {
            /* The part of the region on this line; a newline inside it is one more cell. */
            size_t from = w->region_start > r.start ? w->region_start - r.start : 0;
            size_t to = w->region_end < r.end ? w->region_end - r.start : r.end - r.start;
            if (r.pre) {
                from += from >= r.k ? r.pre : 0;
                to += to >= r.k ? r.pre : 0;
            }
            from = from < lay->nchars ? from : lay->nchars;
            to = to < lay->nchars ? to : lay->nchars;
            float rx = fmaxf(x0 + lay->caret_x[from], left);
            float rr = x0 + lay->caret_x[to];
            if (w->region_end > r.end && line + 1 < lines) {
                rr += st->cell_width;
            }
            rr = fminf(rr, right);
            if (rr > rx) {
                pf_display_rect(d, rx, top, rr - rx, st->line_height,
                                role_color(PF_ROLE_REGION, PF_FACE_HAS_BG, 0));
            }
        }
        if (paren.active) {
            size_t marks[2] = {paren.at, paren.other};
            uint32_t pc = paren.mismatch ? role_color(PF_ROLE_PAREN_MISMATCH, PF_FACE_HAS_BG, 0)
                                         : role_color(PF_ROLE_PAREN_MATCH, PF_FACE_HAS_BG, 0);
            for (int m = 0; m < (paren.found ? 2 : 1); m++) {
                if (marks[m] < r.start || marks[m] >= r.end) {
                    continue;
                }
                size_t idx = marks[m] - r.start;
                if (r.pre && idx >= r.k) {
                    idx += r.pre; /* after the spliced-in composition */
                }
                if (idx < lay->nchars) {
                    float px = fmaxf(x0 + lay->caret_x[idx], left);
                    float pw = fminf(x0 + lay->caret_x[idx + 1], right) - px;
                    pf_display_rect(d, px, top, pw, st->line_height, pc);
                }
            }
        }
        if (w->line_numbers) {
            char num[24];
            int len = snprintf(num, sizeof num, "%zu", line + 1);
            uint32_t ncps[24];
            for (int c = 0; c < len; c++) {
                ncps[c] = (uint32_t)num[c];
            }
            const pf_line_layout *nl = pf_layout_line(w->cache, default_font, ncps, (size_t)len);
            float nx = left - st->cell_width - nl->width; /* right-aligned */
            pf_face_role role = line == point_line ? PF_ROLE_LINE_NUMBER_CURRENT
                                                   : PF_ROLE_LINE_NUMBER;
            emit_glyphs(d, nl, nx, baseline, 0, right, role_color(role, PF_FACE_HAS_FG, fg), NULL,
                        0, (size_t)-1);
        }
        emit_glyphs(d, lay, x0, baseline, left, right, fg, w->fids, 0, (size_t)-1);

        /* Continuation marks: a short bar in the fringe beside text past either edge. */
        float mh = roundf(st->line_height * 0.6f), my = top + (st->line_height - mh) / 2;
        if (lay->nchars && x0 + lay->width > right + 0.5f) {
            pf_display_rect(d, right, my, fmaxf(w->fringe_right, 1.0f / w->scale), mh, mark);
        }
        if (lay->nchars && w->hscroll > 0) {
            pf_display_rect(d, left - gutter - w->fringe_left, my,
                            fmaxf(w->fringe_left, 1.0f / w->scale), mh, mark);
        }

        if (r.here) {
            if (r.pre) {
                float ux = fmaxf(x0 + lay->caret_x[r.k], left);
                float uw = fminf(x0 + lay->caret_x[r.k + r.pre], right) - ux;
                pf_display_rect(d, ux, baseline + st->descent * 0.5f, uw, 1.0f / w->scale,
                                fg); /* one device pixel */
            }
            float cx, cw;
            cursor_span(w, &r, &cx, &cw);
            cx += x0;
            size_t k = r.k + (r.pre ? w->preedit_caret : 0);
            /* Only a cursor inside the text area is drawn (scroll-left can leave point out). */
            int shown = cx >= left - 0.5f && cx + cw <= right + 0.5f;
            uint32_t cc = role_color(PF_ROLE_CURSOR, PF_FACE_HAS_BG, fg);
            float lh = st->line_height, px = 1.0f / w->scale;
            if (shown && w->cursor_kind == PF_CURSOR_BOX) {
                /* Filled box; the character under it is redrawn in the background color. */
                pf_display_rect(d, cx, top, cw, lh, cc);
                if (k < lay->nchars) {
                    emit_glyphs(d, lay, x0, baseline, left, right, bg, NULL, k, k + 1);
                }
            } else if (shown && w->cursor_kind == PF_CURSOR_HOLLOW) {
                pf_display_rect(d, cx, top, cw, px, cc);
                pf_display_rect(d, cx, top + lh - px, cw, px, cc);
                pf_display_rect(d, cx, top, px, lh, cc);
                pf_display_rect(d, cx + cw - px, top, px, lh, cc);
            }
            if (shown) {
                w->cursor[0] = cx;
                w->cursor[1] = top;
                w->cursor[2] = cw;
                w->cursor[3] = lh;
                w->cursor_valid = 1;
            }
        }
    }
}

void pf_window_set_region(pf_window *w, size_t start, size_t end) {
    if (start > end) {
        size_t t = start;
        start = end;
        end = t;
    }
    if (start == end) {
        start = end = 0;
    }
    if (w->region_start != start || w->region_end != end) {
        w->region_start = start;
        w->region_end = end;
        w->dirty = 1;
    }
}

void pf_window_set_canvas(pf_window *w, pf_canvas *canvas) {
    if (w->canvas != canvas) {
        w->canvas = canvas;
        w->cursor_valid = 0;
        w->dirty = 1;
    }
}

pf_canvas *pf_window_canvas(const pf_window *w) {
    return w->canvas;
}

void pf_window_set_native(pf_window *w, uint32_t kind) {
    if (w->native != kind) {
        w->native = kind;
        w->cursor_valid = 0;
        w->dirty = 1;
    }
}

uint32_t pf_window_native(const pf_window *w) {
    return w->native;
}

void pf_window_body_rect(const pf_window *w, float rect[4]) {
    rect[0] = 0;
    rect[1] = 0;
    rect[2] = w->width - w->divider;
    rect[3] = w->height - w->mode_line_h;
}

int pf_window_pos_rect(pf_window *w, size_t pos, float rect[4]) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    if (!s || w->native || w->canvas) {
        return -1;
    }
    const pf_window_style *st = &w->style;
    size_t lines = pf_text_lines(s);
    size_t line = pf_text_line_of(s, pos);
    float body_h = w->height - w->mode_line_h - st->pad_top;
    size_t visible = !w->mode_line.face           ? pf_window_body_lines(w)
                     : st->line_height > 0 && body_h > 0 ? (size_t)ceilf(body_h / st->line_height)
                                                       : 0;
    if (line < w->top || line >= w->top + visible || line >= lines) {
        return -1;
    }
    float right = w->width - w->divider - w->fringe_right;
    float gutter = w->line_numbers ? (float)(count_digits(lines) + 2) * st->cell_width : 0;
    float left = st->pad_left + w->fringe_left + gutter;
    row r = layout_row(w, text, s, line, (size_t)-1, scaled_font(w, default_font_of(w)));
    size_t idx = pos - r.start;
    if (pos < r.start || idx > r.lay->nchars) {
        return -1;
    }
    float x = left - w->hscroll + r.lay->caret_x[idx];
    float cw = idx < r.lay->nchars ? r.lay->caret_x[idx + 1] - r.lay->caret_x[idx] : st->cell_width;
    if (x < left - 0.5f || x + cw > right + 0.5f) {
        return -1;
    }
    rect[0] = x;
    rect[1] = st->pad_top + (float)(line - w->top) * st->line_height;
    rect[2] = cw > 0 ? cw : st->cell_width;
    rect[3] = st->line_height;
    return 0;
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
    uint64_t faces = pf_face_generation();
    uint64_t props = text ? pf_props_generation(pf_text_props(text)) : 0;
    uint64_t cvs_version = w->canvas ? pf_canvas_version(w->canvas) : 0;
    if (!w->dirty && w->canvas == w->shown_canvas && cvs_version == w->shown_canvas_version && s == w->shown && point == w->shown_point && w->top == w->shown_top &&
        faces == w->shown_faces && props == w->shown_props) {
        return NULL;
    }
    w->dirty = 0;
    pf_text_snapshot_release(w->shown);
    w->shown = s ? pf_text_snapshot_retain(s) : NULL;
    w->shown_point = point;
    w->shown_top = w->top;
    w->shown_faces = faces;
    w->shown_props = props;
    w->shown_canvas = w->canvas;
    w->shown_canvas_version = cvs_version;

    uint32_t bg = role_color(PF_ROLE_DEFAULT, PF_FACE_HAS_BG, 0xFFFFFFFF);
    uint32_t fg = role_color(PF_ROLE_DEFAULT, PF_FACE_HAS_FG, 0x000000FF);
    pf_display *d = pf_display_new(w->width, w->height, w->scale, bg);
    w->cursor_valid = 0;
    pf_layout_begin_frame(w->cache);
    float body_h = w->height - w->mode_line_h;
    uint32_t fringe = role_color(PF_ROLE_FRINGE, PF_FACE_HAS_BG, 0);
    if (!w->native && !w->canvas) {
        pf_display_rect(d, 0, 0, w->fringe_left, body_h, fringe);
        pf_display_rect(d, w->width - w->divider - w->fringe_right, 0, w->fringe_right, body_h,
                        fringe);
    }
    if (w->canvas) {
        pf_canvas_env env = {w->cache, w->fonts, default_font_of(w)};
        pf_canvas_render(w->canvas, d, &env, 0, 0);
    } else if (s && !w->native) {
        draw_text(w, d, text, s, point, bg, fg);
    }

    /* Chrome over the text: the divider, the mode line. */
    pf_display_rect(d, w->width - w->divider, 0, w->divider, w->height,
                    role_color(PF_ROLE_VERTICAL_BORDER, PF_FACE_HAS_FG, fg));
    pf_strip_render(&w->mode_line, d, w->cache, w->fonts, default_font_of(w), 0, body_h,
                    w->width - w->divider, w->mode_line_h, w->scale);
    return pf_display_finish(d);
}
