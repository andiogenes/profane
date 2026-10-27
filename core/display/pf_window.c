#include "pf_window.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_anim.h"
#include "pf_boxdraw.h"
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
    pf_strip header;
    float header_h;
    size_t region_start, region_end; /* the active region, empty: none */
    uint32_t native; /* native view kind, 0: text */
    pf_canvas *canvas; /* canvas window: drawn instead of text */
    uint64_t shown_canvas_version;
    const pf_canvas *shown_canvas;
    pf_term *term; /* terminal window: its grid is drawn instead of text */
    uint32_t term_faces[4];
    uint64_t shown_term_version;
    const pf_term *shown_term;
    /* The animated cursor: where the box is drawn (springs toward the cursor's cell), and what the
     * target was relative to. cur_time 0: the animation starts at the next tick. */
    pf_spring cur_x, cur_y;
    pf_spring scroll; /* smooth scrolling: how far below its place the text is drawn, points */
    float scroll_key[2]; /* width, height at the last frame */
    int cur_init;
    size_t cur_top;
    float cur_key[3]; /* hscroll, width, height at the last frame */
    double cur_time;
    uint32_t *marks;            /* fringe marks: line, count, kind */
    size_t nmarks;
    int wrap;                   /* PF_WRAP_* */
    size_t *brk;                /* first character of each screen row of the line last wrapped */
    size_t brk_cap;
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
        free(w->brk);
        free(w->marks);
        pf_strip_free(&w->mode_line);
        pf_strip_free(&w->header);
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
    w->header_h = w->header.face ? pf_strip_height(w->fonts, w->header.face, default_font_of(w),
                                                   w->header.box)
                                 : 0;
}

/* Where the text starts: below the header line and the top padding. */
static float top_inset(const pf_window *w) {
    return w->style.pad_top + w->header_h;
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
                             const pf_strip_run *runs, size_t nruns, uint32_t face, uint32_t box) {
    if (pf_strip_set(&w->mode_line, cps, n, runs, nruns, face, box)) {
        update_mode_line_height(w);
        w->dirty = 1;
    }
}

float pf_window_mode_line_height(const pf_window *w) {
    return w->mode_line_h;
}

void pf_window_set_header_line(pf_window *w, const uint32_t *cps, size_t n,
                               const pf_strip_run *runs, size_t nruns, uint32_t face, uint32_t box) {
    if (pf_strip_set(&w->header, cps, n, runs, nruns, face, box)) {
        update_mode_line_height(w);
        w->dirty = 1;
    }
}

float pf_window_header_line_height(const pf_window *w) {
    return w->header_h;
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
    if (option == PF_WINDOW_WRAP) {
        w->wrap = on == PF_WRAP_CHAR || on == PF_WRAP_WORD ? on : PF_WRAP_NONE;
        w->dirty = 1;
        return 0;
    }
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
           : option == PF_WINDOW_WRAP       ? w->wrap
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
    float usable = w->height - w->mode_line_h - top_inset(w);
    size_t n = lh > 0 && usable > 0 ? (size_t)floorf(usable / lh) : 0;
    return n ? n : 1;
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

/* Background and underline rects for runs of characters [FROM, TO) whose face sets them. */
static void emit_face_decorations(pf_display *d, const pf_line_layout *lay, const uint32_t *fids,
                                  float x0, float left, float right, float top, float baseline,
                                  const pf_window_style *st, float scale, uint32_t default_fg,
                                  size_t from, size_t to) {
    uint32_t def = pf_face_role_id(PF_ROLE_DEFAULT);
    for (size_t i = from; i < to;) {
        size_t j = i + 1;
        while (j < to && fids[j] == fids[i]) {
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

/* The text area's left and right edges (points): the gutter for line numbers is inside it. */
static void text_area(const pf_window *w, const pf_text_snapshot *s, float *left, float *right) {
    float gutter =
        w->line_numbers ? (float)(count_digits(pf_text_lines(s)) + 2) * w->style.cell_width : 0;
    *left = w->style.pad_left + w->fringe_left + gutter;
    *right = w->width - w->divider - w->fringe_right;
}

static int is_blank(uint32_t c) {
    return c == ' ' || c == '\t';
}

/* Splits the line of R (just laid out, so w->cps holds its characters) into screen rows no wider
 * than WIDTH: w->brk[i] is row i's first character. Returns the row count, 1 without wrapping.
 * A row always holds a character; word wrap breaks after whitespace and lets whitespace hang
 * past the edge. */
static size_t wrap_line(pf_window *w, const row *r, float width) {
    const pf_line_layout *lay = r->lay;
    size_t n = lay->nchars, rows = 1, a = 0;
    w->brk = grow(w->brk, &w->brk_cap, 2, sizeof *w->brk);
    w->brk[0] = 0;
    while (w->wrap && width > 0 && a < n) {
        size_t b = a;
        while (b < n && lay->caret_x[b + 1] - lay->caret_x[a] <= width + 0.01f) {
            b++;
        }
        if (b == a) {
            b = a + 1;
        }
        if (b >= n) {
            break;
        }
        if (w->wrap == PF_WRAP_WORD) {
            if (is_blank(w->cps[b])) {
                while (b < n && is_blank(w->cps[b])) {
                    b++;
                }
            } else {
                size_t c = b;
                while (c > a + 1 && !is_blank(w->cps[c - 1])) {
                    c--;
                }
                if (c > a + 1) {
                    b = c;
                }
            }
            if (b >= n) {
                break;
            }
        }
        w->brk = grow(w->brk, &w->brk_cap, rows + 2, sizeof *w->brk);
        w->brk[rows++] = b;
        a = b;
    }
    return rows;
}

/* Screen rows of LINE at the current width. */
static size_t line_rows(pf_window *w, pf_text *text, const pf_text_snapshot *s, size_t line) {
    float left, right;
    text_area(w, s, &left, &right);
    row r = layout_row(w, text, s, line, (size_t)-1, scaled_font(w, default_font_of(w)));
    return wrap_line(w, &r, right - left);
}

/* A screen row: the laid-out line (w->cps, w->brk and the layout stay valid until the next
 * layout_row) and the row's characters [a, b) of it. */
typedef struct vrow {
    row r;
    size_t line, seg, nsegs, a, b;
} vrow;

/* Lays out LINE and picks its screen row: number SEL (BY_INDEX 0), the one holding laid-out
 * character SEL (1), or the last (2). */
static vrow vrow_load(pf_window *w, pf_text *text, const pf_text_snapshot *s, size_t line,
                      size_t sel, int mode) {
    float left, right;
    text_area(w, s, &left, &right);
    vrow v = {0};
    v.line = line;
    v.r = layout_row(w, text, s, line, (size_t)-1, scaled_font(w, default_font_of(w)));
    v.nsegs = wrap_line(w, &v.r, right - left);
    if (mode == 2) {
        v.seg = v.nsegs - 1;
    } else if (mode == 1) {
        while (v.seg + 1 < v.nsegs && w->brk[v.seg + 1] <= sel) {
            v.seg++;
        }
    } else {
        v.seg = sel < v.nsegs ? sel : v.nsegs - 1;
    }
    v.a = w->brk[v.seg];
    v.b = v.seg + 1 < v.nsegs ? w->brk[v.seg + 1] : v.r.lay->nchars;
    return v;
}

/* The laid-out character of V whose cell holds x GOAL (relative to the row's start). */
static size_t vrow_char_at(const vrow *v, float goal) {
    const pf_line_layout *lay = v->r.lay;
    int last = v->seg + 1 == v->nsegs;
    size_t max = last ? v->b : (v->b > v->a ? v->b - 1 : v->a), i = v->a;
    while (i < max && lay->caret_x[i + 1] - lay->caret_x[v->a] <= goal) {
        i++;
    }
    return i;
}

/* Scrolls minimally so the screen row holding POS is fully visible. */
static void keep_visible(pf_window *w, pf_text *text, const pf_text_snapshot *s, size_t pos) {
    size_t line = pf_text_line_of(s, pos), body = pf_window_body_lines(w);
    size_t last = pf_text_lines(s) - 1;
    if (w->top > last) {
        w->top = last;
    }
    if (line < w->top) {
        w->top = line;
        return;
    }
    if (!w->wrap) {
        if (line >= w->top + body) {
            w->top = line - body + 1;
        }
        return;
    }
    /* Rows from the top of the first line that fits above point's row, up to it. */
    vrow v = vrow_load(w, text, s, line, pos - pf_text_line_start(s, line), 1);
    size_t used = v.seg + 1, t = line;
    while (t > 0) {
        size_t above = line_rows(w, text, s, t - 1);
        if (used + above > body) {
            break;
        }
        used += above;
        t--;
    }
    if (w->top < t) {
        w->top = t;
    }
}

int pf_window_row_bounds(pf_window *w, size_t pos, size_t *start, size_t *end) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    if (!s || w->native || w->canvas || w->term) {
        return -1;
    }
    size_t line = pf_text_line_of(s, pos), ls = pf_text_line_start(s, line);
    vrow v = vrow_load(w, text, s, line, pos - ls, 1);
    *start = ls + v.a;
    *end = ls + v.b;
    return 0;
}

float pf_window_row_x(pf_window *w, size_t pos) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    if (!s || w->native || w->canvas || w->term) {
        return 0;
    }
    size_t line = pf_text_line_of(s, pos), ls = pf_text_line_start(s, line);
    vrow v = vrow_load(w, text, s, line, pos - ls, 1);
    size_t i = pos - ls < v.r.lay->nchars ? pos - ls : v.r.lay->nchars;
    return v.r.lay->caret_x[i] - v.r.lay->caret_x[v.a];
}

size_t pf_window_move_rows(pf_window *w, size_t pos, long delta, float goal_x) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    if (!s || w->native || w->canvas || w->term) {
        return pos;
    }
    size_t lines = pf_text_lines(s);
    size_t line = pf_text_line_of(s, pos);
    vrow v = vrow_load(w, text, s, line, pos - pf_text_line_start(s, line), 1);
    size_t seg = v.seg;
    for (; delta > 0; delta--) {
        if (seg + 1 < v.nsegs) {
            seg++;
        } else if (line + 1 < lines) {
            line++;
            seg = 0;
            v = vrow_load(w, text, s, line, 0, 0);
        } else {
            break;
        }
    }
    for (; delta < 0; delta++) {
        if (seg > 0) {
            seg--;
        } else if (line > 0) {
            line--;
            v = vrow_load(w, text, s, line, 0, 2);
            seg = v.seg;
        } else {
            break;
        }
    }
    v = vrow_load(w, text, s, line, seg, 0);
    return pf_text_line_start(s, line) + vrow_char_at(&v, goal_x);
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

static void draw_line_marks(pf_window *w, pf_display *d, size_t line, size_t lines, float top,
                            int first_row, int last_row);

enum { CURSOR_OMEGA = 45 }; /* about 100 ms to settle */

/* Where to draw the cursor box whose cell is at X, Y: springs toward it, except that moves that
 * typing and short motion make (a couple of cells along a row) and jumps the scroll or a resize
 * cause just snap, so the cursor never trails the text it is editing. */
static void cursor_animate(pf_window *w, float x, float y, float *dx, float *dy) {
    float cell = w->style.cell_width;
    float key[3] = {w->hscroll, w->width, w->height};
    int same = w->cur_init && w->cur_top == w->top && memcmp(key, w->cur_key, sizeof key) == 0;
    if (same && (x != w->cur_x.target || y != w->cur_y.target)) {
        if (y == w->cur_y.target && fabsf(x - w->cur_x.target) <= 2 * cell + 0.5f) {
            same = 0;
        } else {
            w->cur_x.target = x;
            w->cur_y.target = y;
            w->cur_time = 0;
        }
    }
    if (!same) {
        pf_spring_snap(&w->cur_x, x);
        pf_spring_snap(&w->cur_y, y);
    }
    w->cur_init = 1;
    w->cur_top = w->top;
    memcpy(w->cur_key, key, sizeof key);
    *dx = w->cur_x.value;
    *dy = w->cur_y.value;
}

static int cursor_moving(const pf_window *w) {
    return w->cur_init && (!pf_spring_settled(&w->cur_x, 0.25f) || !pf_spring_settled(&w->cur_y, 0.25f));
}

static int scroll_moving(const pf_window *w) {
    return !pf_spring_settled(&w->scroll, 0.25f);
}

int pf_window_animating(const pf_window *w) {
    return cursor_moving(w) || scroll_moving(w);
}

enum { SCROLL_OMEGA = 30 }; /* about 150 ms to settle */

/* Called as the window is about to render with its top line changed from OLD_TOP: starts the text
 * gliding from where it was. Edits, big jumps, resizes and a new buffer scroll at once. */
static void scroll_animate(pf_window *w, pf_text *text, const pf_text_snapshot *s, size_t old_top,
                           int text_changed) {
    float key[2] = {w->width, w->height};
    int resized = memcmp(key, w->scroll_key, sizeof key) != 0;
    memcpy(w->scroll_key, key, sizeof key);
    size_t span = w->top > old_top ? w->top - old_top : old_top - w->top;
    if (!text || !pf_motion_scroll() || w->top == old_top) {
        if (!pf_motion_scroll() || resized) {
            pf_spring_snap(&w->scroll, 0);
        }
        return;
    }
    float body_h = w->height - w->mode_line_h - top_inset(w);
    if (resized || text_changed || span > pf_window_body_lines(w)) {
        pf_spring_snap(&w->scroll, 0);
        return;
    }
    long rows = 0;
    size_t lo = w->top < old_top ? w->top : old_top, hi = w->top < old_top ? old_top : w->top;
    for (size_t l = lo; l < hi; l++) {
        rows += w->wrap ? (long)line_rows(w, text, s, l) : 1;
    }
    if (w->top < old_top) {
        rows = -rows;
    }
    float off = w->scroll.value + (float)rows * w->style.line_height;
    if (fabsf(off) > body_h) {
        pf_spring_snap(&w->scroll, 0);
        return;
    }
    w->scroll.value = off;
    w->scroll.target = 0;
    w->cur_time = 0;
}

int pf_window_tick(pf_window *w, double now) {
    if (!pf_window_animating(w)) {
        return 0;
    }
    double dt = w->cur_time == 0 ? 1.0 / 120 : now - w->cur_time;
    w->cur_time = now;
    w->dirty = 1;
    /* A late frame (the main thread was busy) or motion switched off: arrive now. */
    int late = dt > 0.05;
    if (late || !pf_motion_cursor()) {
        pf_spring_snap(&w->cur_x, w->cur_x.target);
        pf_spring_snap(&w->cur_y, w->cur_y.target);
    } else {
        pf_spring_step(&w->cur_x, CURSOR_OMEGA, (float)dt);
        pf_spring_step(&w->cur_y, CURSOR_OMEGA, (float)dt);
    }
    if (late || !pf_motion_scroll()) {
        pf_spring_snap(&w->scroll, 0);
    } else {
        pf_spring_step(&w->scroll, SCROLL_OMEGA, (float)dt);
    }
    if (!cursor_moving(w)) {
        pf_spring_snap(&w->cur_x, w->cur_x.target);
        pf_spring_snap(&w->cur_y, w->cur_y.target);
    }
    if (!scroll_moving(w)) {
        pf_spring_snap(&w->scroll, 0);
    }
    return pf_window_animating(w);
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
    float body_h = w->height - w->mode_line_h - top_inset(w);
    size_t visible = !w->mode_line.face           ? pf_window_body_lines(w)
                     : st->line_height > 0 && body_h > 0 ? (size_t)ceilf(body_h / st->line_height)
                                                       : 0;
    size_t point_line = pf_text_line_of(s, point);
    paren_match paren = w->show_paren ? find_paren(w, s, point) : (paren_match){0};
    float left, right; /* the text area, after the gutter sized for the last line number */
    text_area(w, s, &left, &right);
    float gutter = left - st->pad_left - w->fringe_left;
    if (w->wrap) {
        w->hscroll = 0;
    } else if (point_line >= w->top && point_line < w->top + visible) {
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

    /* Smooth scrolling: rows are drawn off points lower (higher, if negative) than their place,
     * clipped to the body, with the row just above the window shown when they are lower. */
    float off = w->scroll.value;
    long srow = 0, limit = (long)visible + (off < 0 ? 1 : 0); /* screen rows drawn; rows to draw */
    if (off != 0) {
        pf_display_clip(d, 0, w->header_h, w->width - w->divider,
                        w->height - w->mode_line_h - w->header_h);
    }
    for (size_t line = off > 0 && w->top > 0 ? w->top - 1 : w->top; srow < limit && line < lines;
         line++) {
        row r = layout_row(w, text, s, line, point, default_font);
        const pf_line_layout *lay = r.lay;
        size_t nsegs = wrap_line(w, &r, right - left);
        if (line < w->top) {
            srow = -(long)nsegs;
        }
        for (size_t seg = 0; seg < nsegs && srow < limit; seg++, srow++) {
        if (srow < -1) {
            continue;
        }
        size_t a = w->brk[seg], b = seg + 1 < nsegs ? w->brk[seg + 1] : lay->nchars;
        int last = seg + 1 == nsegs;
        float xs = w->wrap ? left - lay->caret_x[a] : x0; /* where this row's line start would be */
        float top = top_inset(w) + off + (float)srow * st->line_height;
        float baseline = top + st->ascent;

        /* Backgrounds first: faces, the hl-line band (an overlay in Emacs, so above them), then
         * bracket highlights. */
        emit_face_decorations(d, lay, w->fids, xs, left, right, top, baseline, st, w->scale, fg, a,
                              b);
        if (w->hl_line && line == point_line) {
            pf_display_rect(d, left, top, right - left, st->line_height,
                            role_color(PF_ROLE_HL_LINE, PF_FACE_HAS_BG, 0));
        }
        if (w->region_end > r.start && w->region_start <= r.end && w->region_start != w->region_end) {
            /* The part of the region on this row; a newline inside it is one more cell. */
            size_t from = w->region_start > r.start ? w->region_start - r.start : 0;
            size_t to = w->region_end < r.end ? w->region_end - r.start : r.end - r.start;
            if (r.pre) {
                from += from >= r.k ? r.pre : 0;
                to += to >= r.k ? r.pre : 0;
            }
            from = from < lay->nchars ? from : lay->nchars;
            to = to < lay->nchars ? to : lay->nchars;
            from = from > a ? from : a;
            to = to < b ? to : b;
            float rx = fmaxf(xs + lay->caret_x[from], left);
            float rr = xs + lay->caret_x[to > from ? to : from];
            if (last && w->region_end > r.end && line + 1 < lines) {
                rr += st->cell_width;
            }
            rr = fminf(rr, right);
            if ((to > from || (last && w->region_end > r.end && line + 1 < lines)) && rr > rx) {
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
                if (idx >= a && idx < b && idx < lay->nchars) {
                    float px = fmaxf(xs + lay->caret_x[idx], left);
                    float pw = fminf(xs + lay->caret_x[idx + 1], right) - px;
                    pf_display_rect(d, px, top, pw, st->line_height, pc);
                }
            }
        }
        if (w->line_numbers && seg == 0) {
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
        emit_glyphs(d, lay, xs, baseline, left, right, fg, w->fids, a, b);
        if (w->nmarks) {
            draw_line_marks(w, d, line, lines, top, seg == 0, last);
        }

        /* Continuation marks: a short bar in the fringe beside text past either edge, or at the
         * right of a row the line goes on from. */
        float mh = roundf(st->line_height * 0.6f), my = top + (st->line_height - mh) / 2;
        if (w->wrap ? !last : lay->nchars && x0 + lay->width > right + 0.5f) {
            pf_display_rect(d, right, my, fmaxf(w->fringe_right, 1.0f / w->scale), mh, mark);
        }
        if (!w->wrap && lay->nchars && w->hscroll > 0) {
            pf_display_rect(d, left - gutter - w->fringe_left, my,
                            fmaxf(w->fringe_left, 1.0f / w->scale), mh, mark);
        }

        /* Point's row: the last one whose first character is at or before it. */
        if (r.here && r.k >= a && (r.k < b || last)) {
            if (r.pre) {
                float ux = fmaxf(xs + lay->caret_x[r.k], left);
                float uw = fminf(xs + lay->caret_x[r.k + r.pre], right) - ux;
                pf_display_rect(d, ux, baseline + st->descent * 0.5f, uw, 1.0f / w->scale,
                                fg); /* one device pixel */
            }
            float cx, cw;
            cursor_span(w, &r, &cx, &cw);
            cx += xs;
            size_t k = r.k + (r.pre ? w->preedit_caret : 0);
            /* Only a cursor inside the text area is drawn (scroll-left can leave point out). */
            int shown = cx >= left - 0.5f && cx + cw <= right + 0.5f;
            uint32_t cc = role_color(PF_ROLE_CURSOR, PF_FACE_HAS_BG, fg);
            float lh = st->line_height, px = 1.0f / w->scale;
            float ax = cx, ay = top; /* where the box is drawn */
            if (shown && w->cursor_kind == PF_CURSOR_BOX && pf_motion_cursor() && off == 0) {
                cursor_animate(w, cx, top, &ax, &ay);
            } else {
                w->cur_init = 0;
            }
            if (shown && w->cursor_kind == PF_CURSOR_BOX) {
                /* Filled box; the character under it is redrawn in the background color once the
                 * box has arrived. */
                pf_display_rect(d, ax, ay, cw, lh, cc);
                if (k < lay->nchars && ax == cx && ay == top) {
                    emit_glyphs(d, lay, xs, baseline, left, right, bg, NULL, k, k + 1);
                }
            } else if (shown && w->cursor_kind == PF_CURSOR_HOLLOW) {
                pf_display_rect(d, cx, top, cw, px, cc);
                pf_display_rect(d, cx, top + lh - px, cw, px, cc);
                pf_display_rect(d, cx, top, px, lh, cc);
                pf_display_rect(d, cx + cw - px, top, px, lh, cc);
            }
            if (shown) {
                w->cursor[0] = cx;
                w->cursor[1] = top - off;
                w->cursor[2] = cw;
                w->cursor[3] = lh;
                w->cursor_valid = 1;
            }
        }
        }
    }
    if (off != 0) {
        pf_display_unclip(d);
    }
}

void pf_window_set_line_marks(pf_window *w, const uint32_t *triples, size_t n) {
    free(w->marks);
    w->marks = n ? xrealloc(NULL, n * 3 * sizeof *w->marks) : NULL;
    if (n) {
        memcpy(w->marks, triples, n * 3 * sizeof *w->marks);
    }
    w->nmarks = n;
    w->dirty = 1;
}

/* The fringe mark bars for buffer LINE of a row [TOP, TOP + line_height) (BOTTOM: the last line,
 * for a deletion after it). */
static void draw_line_marks(pf_window *w, pf_display *d, size_t line, size_t lines, float top,
                            int first_row, int last_row) {
    float bar = fmaxf(w->fringe_left, 2.0f), lh = w->style.line_height, px = 1.0f / w->scale;
    for (size_t i = 0; i < w->nmarks; i++) {
        uint32_t ml = w->marks[3 * i], count = w->marks[3 * i + 1], kind = w->marks[3 * i + 2];
        if (kind == 3) {
            int here = ml == line && first_row, after = ml >= lines && line + 1 == lines && last_row;
            if (here || after) {
                float y = here ? top : top + lh - 2 * px;
                pf_display_rect(d, 0, y, bar * 2, 2 * px,
                                role_color(PF_ROLE_GIT_DELETED, PF_FACE_HAS_FG, 0));
            }
        } else if (line >= ml && line < (size_t)ml + count) {
            pf_display_rect(d, 0, top, bar, lh,
                            role_color(kind == 1 ? PF_ROLE_GIT_ADDED : PF_ROLE_GIT_MODIFIED,
                                       PF_FACE_HAS_FG, 0));
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

void pf_window_set_terminal(pf_window *w, pf_term *term, const uint32_t faces[4]) {
    if (w->term != term || (term && memcmp(w->term_faces, faces, sizeof w->term_faces) != 0)) {
        w->term = term;
        if (term) {
            memcpy(w->term_faces, faces, sizeof w->term_faces);
        }
        w->cursor_valid = 0;
        w->dirty = 1;
    }
}

pf_term *pf_window_terminal(const pf_window *w) {
    return w->term;
}

void pf_window_terminal_size(const pf_window *w, int *rows, int *cols) {
    float body_h = w->height - w->mode_line_h - w->header_h;
    float body_w = w->width - w->divider;
    int r = w->style.line_height > 0 ? (int)floorf(body_h / w->style.line_height) : 1;
    int c = w->style.cell_width > 0 ? (int)floorf(body_w / w->style.cell_width) : 1;
    if (rows) {
        *rows = r < 1 ? 1 : r;
    }
    if (cols) {
        *cols = c < 1 ? 1 : c;
    }
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
    rect[1] = w->header_h;
    rect[2] = w->width - w->divider;
    rect[3] = w->height - w->mode_line_h - w->header_h;
}

int pf_window_pos_rect(pf_window *w, size_t pos, float rect[4]) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    if (!s || w->native || w->canvas || w->term) {
        return -1;
    }
    const pf_window_style *st = &w->style;
    size_t lines = pf_text_lines(s);
    size_t line = pf_text_line_of(s, pos);
    float body_h = w->height - w->mode_line_h - top_inset(w);
    size_t visible = !w->mode_line.face           ? pf_window_body_lines(w)
                     : st->line_height > 0 && body_h > 0 ? (size_t)ceilf(body_h / st->line_height)
                                                       : 0;
    if (line < w->top || line >= lines) {
        return -1;
    }
    size_t srow = 0; /* screen rows above the line */
    for (size_t l = w->top; l < line && srow < visible; l++) {
        srow += line_rows(w, text, s, l);
    }
    if (srow >= visible) {
        return -1;
    }
    float left, right;
    text_area(w, s, &left, &right);
    size_t idx = pos - pf_text_line_start(s, line);
    vrow v = vrow_load(w, text, s, line, idx, 1);
    if (srow + v.seg >= visible || idx > v.r.lay->nchars) {
        return -1;
    }
    const pf_line_layout *lay = v.r.lay;
    float x = (w->wrap ? left - lay->caret_x[v.a] : left - w->hscroll) + lay->caret_x[idx];
    float cw = idx < lay->nchars ? lay->caret_x[idx + 1] - lay->caret_x[idx] : st->cell_width;
    if (x < left - 0.5f || x + cw > right + 0.5f) {
        return -1;
    }
    rect[0] = x;
    rect[1] = top_inset(w) + (float)(srow + v.seg) * st->line_height;
    rect[2] = cw > 0 ? cw : st->cell_width;
    rect[3] = st->line_height;
    return 0;
}

int64_t pf_window_pos_at(pf_window *w, float x, float y) {
    pf_text *text = pf_handle_get(w->buf, PF_HANDLE_TEXT);
    const pf_text_snapshot *s = text ? pf_text_current(text) : NULL;
    if (!s || w->native || w->canvas || w->term) {
        return -1;
    }
    const pf_window_style *st = &w->style;
    float body_bottom = w->height - w->mode_line_h;
    if (y >= body_bottom || st->line_height <= 0) {
        return -1;
    }
    size_t lines = pf_text_lines(s);
    size_t target = y < top_inset(w) ? 0 : (size_t)((y - top_inset(w)) / st->line_height);
    size_t line = w->top, srow = 0, nrows = 1;
    for (; line < lines; line++) {
        nrows = line_rows(w, text, s, line);
        if (target < srow + nrows) {
            break;
        }
        srow += nrows;
    }
    int past = line >= lines; /* below the last line: its end */
    if (past) {
        line = lines - 1;
    }
    float left, right;
    text_area(w, s, &left, &right);
    vrow v = vrow_load(w, text, s, line, past ? nrows : target - srow, past ? 2 : 0);
    float rx = x - (w->wrap ? left : left - w->hscroll);
    size_t idx = vrow_char_at(&v, rx);
    if (!w->wrap) {
        /* An unwrapped row is the whole line; x may also be left of the scrolled-out start. */
        idx = 0;
        while (idx < v.r.lay->nchars && v.r.lay->caret_x[idx + 1] <= rx) {
            idx++;
        }
    }
    return (int64_t)(v.r.start + idx);
}

/* The terminal grid: background runs, then the cursor, then the glyphs of each cell in the font
 * of its attributes (a cell is shaped on its own, so a wide or fallback glyph never shifts its
 * neighbors; the layout cache makes repeats free). */
static void draw_terminal(pf_window *w, pf_display *d, float body_h, uint32_t window_fg) {
    pf_term *t = w->term;
    const float cw = w->style.cell_width, lh = w->style.line_height;
    const float y0 = w->header_h;
    const int rows = pf_term_rows(t), cols = pf_term_cols(t);
    uint32_t fonts[4];
    for (int i = 0; i < 4; i++) {
        uint32_t f = pf_face_get(w->term_faces[i])->font;
        fonts[i] = f ? f : default_font_of(w);
    }
    int curs_row, curs_col, curs_visible, curs_shape, curs_blink;
    pf_term_cursor(t, &curs_row, &curs_col, &curs_visible, &curs_shape, &curs_blink);
    uint32_t cursor_color = role_color(PF_ROLE_CURSOR, PF_FACE_HAS_BG, window_fg);
    int cursor_kind = curs_visible ? w->cursor_kind : PF_CURSOR_NONE;
    float cursor_w = cw;

    /* backgrounds, in horizontal runs of one color */
    for (int r = 0; r < rows; r++) {
        float y = y0 + (float)r * lh;
        if (y + lh > body_h + 0.01f) {
            break;
        }
        int c = 0;
        while (c < cols) {
            pf_term_cell cell;
            pf_term_cell_get(t, r, c, &cell);
            if (cell.bg_default) {
                c++;
                continue;
            }
            int start = c;
            uint32_t color = cell.bg;
            while (c < cols) {
                pf_term_cell_get(t, r, c, &cell);
                if (cell.bg_default || cell.bg != color) {
                    break;
                }
                c++;
            }
            pf_display_rect(d, (float)start * cw, y, (float)(c - start) * cw, lh, color);
        }
    }

    /* the cursor: below the glyphs when it is a box, so the glyph shows through in the cell's color */
    if (cursor_kind != PF_CURSOR_NONE && curs_row >= 0 && curs_row < rows && curs_col >= 0 &&
        curs_col < cols) {
        pf_term_cell under;
        pf_term_cell_get(t, curs_row, curs_col, &under);
        cursor_w = under.width == 2 ? 2 * cw : cw;
        float x = (float)curs_col * cw, y = y0 + (float)curs_row * lh;
        w->cursor[0] = x;
        w->cursor[1] = y;
        w->cursor[2] = cursor_w;
        w->cursor[3] = lh;
        w->cursor_valid = 1;
        if (cursor_kind == PF_CURSOR_HOLLOW) {
            pf_display_rect(d, x, y, cursor_w, 1, cursor_color);
            pf_display_rect(d, x, y + lh - 1, cursor_w, 1, cursor_color);
            pf_display_rect(d, x, y, 1, lh, cursor_color);
            pf_display_rect(d, x + cursor_w - 1, y, 1, lh, cursor_color);
        } else if (curs_shape == 2) {
            pf_display_rect(d, x, y + lh - 2, cursor_w, 2, cursor_color);
        } else if (curs_shape == 3) {
            pf_display_rect(d, x, y, 2, lh, cursor_color);
        } else {
            pf_display_rect(d, x, y, cursor_w, lh, cursor_color);
        }
    }

    float ascent = roundf(w->style.ascent);
    for (int r = 0; r < rows; r++) {
        float y = y0 + (float)r * lh;
        if (y + lh > body_h + 0.01f) {
            break;
        }
        float baseline = y + ascent;
        for (int c = 0; c < cols; c++) {
            pf_term_cell cell;
            pf_term_cell_get(t, r, c, &cell);
            if (cell.width == 0 || cell.cps[0] == 0 || cell.conceal) {
                continue;
            }
            size_t n = 0;
            while (n < PF_TERM_MAX_CPS && cell.cps[n]) {
                n++;
            }
            int blank = n == 1 && cell.cps[0] == ' ';
            int boxed = cursor_kind == PF_CURSOR_BOX && curs_shape == 1 && r == curs_row && c == curs_col;
            uint32_t color = boxed ? (cell.bg_default ? role_color(PF_ROLE_DEFAULT, PF_FACE_HAS_BG, 0xFFFFFFFF) : cell.bg)
                                   : cell.fg;
            uint32_t font = fonts[(cell.bold ? 1 : 0) | (cell.italic ? 2 : 0)];
            float x = (float)c * cw;
            int drawn = !blank && n == 1 && pf_boxdraw(d, cell.cps[0], x, y, cw, lh, color);
            if (!blank && !drawn) {
                const pf_line_layout *lay = pf_layout_line(w->cache, font, cell.cps, n);
                for (size_t g = 0; g < lay->nglyphs; g++) {
                    pf_display_glyph(d, lay->glyphs[g].font, lay->glyphs[g].glyph, x + lay->glyphs[g].x,
                                     baseline, color);
                }
            }
            float span = cell.width == 2 ? 2 * cw : cw;
            if (cell.underline) {
                pf_display_rect(d, x, baseline + 1, span, 1, color);
                if (cell.underline == 2) {
                    pf_display_rect(d, x, baseline + 3, span, 1, color);
                }
            }
            if (cell.strike) {
                pf_display_rect(d, x, baseline - roundf(w->style.ascent / 3), span, 1, color);
            }
        }
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
        keep_visible(w, text, s, point);
    }
    uint64_t faces = pf_face_generation();
    uint64_t props = text ? pf_props_generation(pf_text_props(text)) : 0;
    uint64_t cvs_version = w->canvas ? pf_canvas_version(w->canvas) : 0;
    uint64_t term_version = w->term ? pf_term_version(w->term) : 0;
    if (!w->dirty && w->term == w->shown_term && term_version == w->shown_term_version &&
        w->canvas == w->shown_canvas && cvs_version == w->shown_canvas_version && s == w->shown && point == w->shown_point && w->top == w->shown_top &&
        faces == w->shown_faces && props == w->shown_props) {
        return NULL;
    }
    w->dirty = 0;
    scroll_animate(w, text, s, w->shown_top, s != w->shown);
    pf_text_snapshot_release(w->shown);
    w->shown = s ? pf_text_snapshot_retain(s) : NULL;
    w->shown_point = point;
    w->shown_top = w->top;
    w->shown_faces = faces;
    w->shown_props = props;
    w->shown_canvas = w->canvas;
    w->shown_canvas_version = cvs_version;
    w->shown_term = w->term;
    w->shown_term_version = term_version;

    uint32_t bg = role_color(PF_ROLE_DEFAULT, PF_FACE_HAS_BG, 0xFFFFFFFF);
    uint32_t fg = role_color(PF_ROLE_DEFAULT, PF_FACE_HAS_FG, 0x000000FF);
    pf_display *d = pf_display_new(w->width, w->height, w->scale, bg);
    w->cursor_valid = 0;
    pf_layout_begin_frame(w->cache);
    float body_h = w->height - w->mode_line_h;
    uint32_t fringe = role_color(PF_ROLE_FRINGE, PF_FACE_HAS_BG, 0);
    if (!w->native && !w->canvas && !w->term) {
        pf_display_rect(d, 0, w->header_h, w->fringe_left, body_h - w->header_h, fringe);
        pf_display_rect(d, w->width - w->divider - w->fringe_right, w->header_h, w->fringe_right,
                        body_h - w->header_h, fringe);
    }
    if (w->term) {
        draw_terminal(w, d, body_h, fg);
    } else if (w->canvas) {
        pf_canvas_env env = {w->cache, w->fonts, default_font_of(w)};
        pf_canvas_render(w->canvas, d, &env, 0, w->header_h);
    } else if (s && !w->native) {
        draw_text(w, d, text, s, point, bg, fg);
    }

    /* Chrome over the text: the divider, the mode line. */
    pf_display_rect(d, w->width - w->divider, 0, w->divider, w->height,
                    role_color(PF_ROLE_VERTICAL_BORDER, PF_FACE_HAS_FG, fg));
    pf_strip_render(&w->header, d, w->cache, w->fonts, default_font_of(w), 0, 0,
                    w->width - w->divider, w->header_h, w->scale);
    pf_strip_render(&w->mode_line, d, w->cache, w->fonts, default_font_of(w), 0, body_h,
                    w->width - w->divider, w->mode_line_h, w->scale);
    return pf_display_finish(d);
}
