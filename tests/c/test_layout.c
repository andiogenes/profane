/* Layout cache and window display with a fake monospace shaper: every character is a 10 pt
 * glyph whose id is its code point, except "fi", which becomes one ligature glyph (id 0xFB01). */

#include <math.h>
#include <string.h>

#include "pf_buffer_ffi.h"
#include "pf_face.h"
#include "pf_props.h"
#include "pf_layout.h"
#include "pf_test.h"
#include "pf_text.h"
#include "pf_window.h"

static int shape_calls;

static float fake_shape(void *ctx, uint32_t font, const uint32_t *cps, size_t n, pf_shaped *out) {
    (void)ctx;
    shape_calls++;
    float x = 0;
    for (size_t i = 0; i < n; i++) {
        if (cps[i] == 'f' && i + 1 < n && cps[i + 1] == 'i') {
            pf_shaped_push(out, font, 0xFB01, x, (uint32_t)i);
            x += 20;
            i++;
            continue;
        }
        pf_shaped_push(out, font, cps[i], x, (uint32_t)i);
        x += 10;
    }
    return x;
}

static float fake_cell(void *ctx, uint32_t font) {
    (void)ctx, (void)font;
    return 10;
}

static const pf_shaper fake = {NULL, fake_shape, fake_cell};

static size_t to_cps(const char *s, uint32_t *out) {
    size_t n = 0;
    while (*s) {
        out[n++] = (unsigned char)*s++;
    }
    return n;
}

#define NEAR(a, b) (fabsf((a) - (b)) < 1e-3f)

static void test_layout(void) {
    pf_layout_cache *c = pf_layout_cache_new(fake, 4, 4);
    uint32_t cps[64];

    size_t n = to_cps("ab\tc", cps);
    const pf_line_layout *l = pf_layout_line(c, 1, cps, n);
    PF_CHECK_EQ_SIZE(l->nglyphs, 3); /* the tab draws nothing */
    PF_CHECK(NEAR(l->caret_x[0], 0) && NEAR(l->caret_x[1], 10) && NEAR(l->caret_x[2], 20));
    PF_CHECK(NEAR(l->caret_x[3], 40)); /* tab stop: 4 cells */
    PF_CHECK(NEAR(l->width, 50) && NEAR(l->caret_x[4], 50));
    PF_CHECK(l->glyphs[2].glyph == 'c' && NEAR(l->glyphs[2].x, 40) && l->glyphs[2].cluster == 3);

    n = to_cps("\t\tx", cps);
    l = pf_layout_line(c, 1, cps, n);
    PF_CHECK(NEAR(l->caret_x[1], 40) && NEAR(l->caret_x[2], 80));

    /* Inside a ligature the caret is interpolated across the glyph. */
    n = to_cps("efit", cps);
    l = pf_layout_line(c, 1, cps, n);
    PF_CHECK_EQ_SIZE(l->nglyphs, 3);
    PF_CHECK(NEAR(l->caret_x[1], 10) && NEAR(l->caret_x[2], 20) && NEAR(l->caret_x[3], 30));

    /* Cached by content and font. */
    int before = shape_calls;
    PF_CHECK(pf_layout_line(c, 1, cps, n) == l);
    PF_CHECK(shape_calls == before);
    PF_CHECK(pf_layout_line(c, 2, cps, n) != l); /* other font: separate entry */
    n = to_cps("", cps);
    PF_CHECK(pf_layout_line(c, 1, cps, 0)->nchars == 0);

    /* Eviction happens at frame starts and spares the most recently used lines. */
    pf_layout_stats st = pf_layout_cache_stats(c);
    PF_CHECK(st.entries == 5 && st.hits == 1);
    pf_layout_begin_frame(c);
    st = pf_layout_cache_stats(c);
    PF_CHECK(st.entries == 4 && st.evictions == 1);
    n = to_cps("efit", cps);
    before = shape_calls;
    pf_layout_line(c, 1, cps, n); /* recently used: survived */
    PF_CHECK(shape_calls == before);
    n = to_cps("ab\tc", cps);
    pf_layout_line(c, 1, cps, n); /* least recently used: was evicted */
    PF_CHECK(shape_calls == before + 2); /* reshaped, one call per tab-separated segment */
    pf_layout_cache_free(c);
}

/* Role faces with the colors the checks below expect. Face ids are arbitrary. */
static void set_role(pf_face_role role, uint32_t id, uint32_t flags, uint32_t fg, uint32_t bg) {
    pf_face f = {.flags = flags, .fg = fg, .bg = bg};
    pf_face_set(id, &f);
    pf_face_set_role(role, id);
}

static pf_window_style style(void) {
    set_role(PF_ROLE_DEFAULT, 1, PF_FACE_HAS_FG | PF_FACE_HAS_BG, 0x000000FF, 0xFFFFFFFF);
    set_role(PF_ROLE_CURSOR, 2, PF_FACE_HAS_BG, 0, 0xFF0000FF);
    set_role(PF_ROLE_LINE_NUMBER, 3, PF_FACE_HAS_FG, 0x888888FF, 0);
    set_role(PF_ROLE_LINE_NUMBER_CURRENT, 4, PF_FACE_HAS_FG, 0x111111FF, 0);
    set_role(PF_ROLE_HL_LINE, 5, PF_FACE_HAS_BG, 0, 0xEEEEEEFF);
    set_role(PF_ROLE_PAREN_MATCH, 6, PF_FACE_HAS_BG, 0, 0x00FF00FF);
    set_role(PF_ROLE_PAREN_MISMATCH, 7, PF_FACE_HAS_BG, 0, 0xFF00FFFF);
    return (pf_window_style){
        .font = 1, .ascent = 12, .descent = 4, .line_height = 20, .cell_width = 10,
        .pad_left = 5, .pad_top = 0};
}

static size_t count_kind(const pf_display *d, uint32_t kind) {
    size_t n = 0;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        n += pf_display_items(d)[i].kind == kind;
    }
    return n;
}

static void test_window(void) {
    pf_layout_cache *cache = pf_layout_cache_new(fake, 256, 8);
    pf_window_style s = style();
    pf_window *w = pf_window_new(cache, &s);
    pf_window_set_size(w, 200, 100, 2); /* 5 full lines */
    PF_CHECK_EQ_SIZE(pf_window_body_lines(w), 5);

    const char *text = "one\ntwo\nthree\n";
    pf_handle buf = pf_buf_new(text, strlen(text));
    uint32_t point = pf_buf_marker_new(buf, 4, 0); /* start of "two" */
    pf_window_set_buffer(w, buf, point);

    const pf_display *d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    PF_CHECK(pf_display_clear(d) == 0xFFFFFFFF && pf_display_scale(d) == 2);
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_GLYPH), 11 + 1); /* + glyph redrawn under cursor */
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_RECT), 1);
    const pf_display_item *it = pf_display_items(d);
    PF_CHECK(it[0].u.glyph.glyph == 'o' && NEAR(it[0].x, 5) && NEAR(it[0].y, 12));
    PF_CHECK(it[3].u.glyph.glyph == 't' && NEAR(it[3].y, 32)); /* second line baseline */
    /* Cursor: box at "t" of "two", then "t" again in the background color. */
    const pf_display_item *cursor = &it[6];
    PF_CHECK(cursor->kind == PF_DISPLAY_RECT && NEAR(cursor->x, 5) && NEAR(cursor->y, 20));
    PF_CHECK(NEAR(cursor->u.rect.w, 10) && NEAR(cursor->u.rect.h, 20) && cursor->color == 0xFF0000FF);
    PF_CHECK(it[7].u.glyph.glyph == 't' && it[7].color == 0xFFFFFFFF);
    pf_display_release(d);

    PF_CHECK(pf_window_redisplay(w) == NULL); /* nothing changed */

    /* Moving point or editing re-renders. */
    pf_buf_marker_set(buf, point, 14); /* end of buffer: empty last line */
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    const pf_display_item *last = &pf_display_items(d)[pf_display_count(d) - 1];
    PF_CHECK(last->kind == PF_DISPLAY_RECT && NEAR(last->y, 60) && NEAR(last->u.rect.w, 10));
    pf_display_release(d);
    pf_buf_insert(buf, 0, "x", 1);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    pf_display_release(d);

    /* Point below the window scrolls just enough to show it. */
    for (int i = 0; i < 20; i++) {
        pf_buf_insert(buf, (size_t)pf_buf_chars(buf), "line\n", 5);
    }
    pf_buf_marker_set(buf, point, (size_t)pf_buf_chars(buf));
    d = pf_window_redisplay(w);
    PF_CHECK_EQ_SIZE(pf_window_top_line(w), 23 - 5 + 1);
    pf_display_release(d);
    pf_buf_marker_set(buf, point, 0);
    d = pf_window_redisplay(w);
    PF_CHECK_EQ_SIZE(pf_window_top_line(w), 0);
    pf_display_release(d);

    /* Long lines are truncated at the window edge. */
    char wide[64];
    memset(wide, 'w', sizeof wide);
    pf_buf_insert(buf, 0, wide, sizeof wide);
    pf_window_invalidate(w);
    d = pf_window_redisplay(w);
    float max_x = 0;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        if (pf_display_items(d)[i].x > max_x) {
            max_x = pf_display_items(d)[i].x;
        }
    }
    PF_CHECK(max_x <= 200);
    pf_display_release(d);

    /* Input-method composition: drawn at point, underlined, cursor inside it; not in the buffer. */
    pf_buf_delete(buf, 0, (size_t)pf_buf_chars(buf));
    pf_buf_insert(buf, 0, "ab", 2);
    pf_buf_marker_set(buf, point, 1);
    uint32_t composing[] = {'X', 'Y', 'Z'};
    pf_window_set_preedit(w, composing, 3, 2);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    char shown[8] = {0};
    size_t ns = 0;
    const pf_display_item *underline = NULL, *box = NULL;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *x = &pf_display_items(d)[i];
        if (x->kind == PF_DISPLAY_GLYPH && x->color == 0x000000FF && ns < 7) {
            shown[ns++] = (char)x->u.glyph.glyph;
        } else if (x->kind == PF_DISPLAY_RECT && x->color == 0x000000FF) {
            underline = x;
        } else if (x->kind == PF_DISPLAY_RECT) {
            box = x;
        }
    }
    PF_CHECK_EQ_STR(shown, "aXYZb");
    PF_CHECK(underline && NEAR(underline->x, 15) && NEAR(underline->u.rect.w, 30));
    PF_CHECK(NEAR(underline->u.rect.h, 0.5f)); /* one device pixel at scale 2 */
    PF_CHECK(box && NEAR(box->x, 35)); /* caret 2 into the composition: on "Z" */
    float rect[4];
    PF_CHECK(pf_window_cursor_rect(w, rect) == 0 && NEAR(rect[0], 35) && NEAR(rect[1], 0));
    PF_CHECK_EQ_SIZE((size_t)pf_buf_chars(buf), 2);
    pf_display_release(d);
    pf_window_set_preedit(w, NULL, 0, 0);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL && count_kind(d, PF_DISPLAY_GLYPH) == 2 + 1);
    pf_display_release(d);

    /* A killed buffer shows an empty window instead of crashing. */
    pf_buf_free(buf);
    pf_window_invalidate(w);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL && pf_display_count(d) == 0);
    PF_CHECK(pf_window_cursor_rect(w, rect) == -1);
    pf_display_release(d);

    pf_window_free(w);
    pf_layout_cache_free(cache);
}

static const pf_display_item *find_rect(const pf_display *d, uint32_t color, size_t nth) {
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *x = &pf_display_items(d)[i];
        if (x->kind == PF_DISPLAY_RECT && x->color == color && nth-- == 0) {
            return x;
        }
    }
    return NULL;
}

static size_t count_color(const pf_display *d, uint32_t kind, uint32_t color) {
    size_t n = 0;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *x = &pf_display_items(d)[i];
        n += x->kind == kind && x->color == color;
    }
    return n;
}

/* Redisplay with point at POS (forcing a frame). */
static const pf_display *frame_at(pf_window *w, pf_handle buf, uint32_t point, size_t pos) {
    pf_buf_marker_set(buf, point, pos);
    pf_window_invalidate(w);
    return pf_window_redisplay(w);
}

static void test_editing_modes(void) {
    pf_layout_cache *cache = pf_layout_cache_new(fake, 256, 8);
    pf_window_style s = style();
    pf_window *w = pf_window_new(cache, &s);
    pf_window_set_size(w, 400, 200, 1);
    PF_CHECK(pf_window_set_option(w, (pf_window_option)99, 1) == -1);
    PF_CHECK(pf_window_option_value(w, PF_WINDOW_LINE_NUMBERS) == 0);

    /* 12 lines: two-digit line numbers. */
    const char *text = "(a [b] c)\n{\n}\n(x]\n4\n5\n6\n7\n8\n9\n10\n11";
    pf_handle buf = pf_buf_new(text, strlen(text));
    uint32_t point = pf_buf_marker_new(buf, 0, 0);
    pf_window_set_buffer(w, buf, point);

    /* Line numbers: gutter of (2 digits + 2) cells; text shifts right; current line emphasized. */
    pf_window_set_option(w, PF_WINDOW_LINE_NUMBERS, 1);
    const pf_display *d = frame_at(w, buf, point, 0);
    const pf_display_item *it = pf_display_items(d);
    size_t i = 0;
    while (it[i].kind != PF_DISPLAY_GLYPH || it[i].u.glyph.glyph != '1') {
        i++;
    }
    PF_CHECK(NEAR(it[i].x, 5 + 40 - 10 - 10)); /* "1" right-aligned before the last cell */
    PF_CHECK(it[i].color == 0x111111FF);
    /* 10 rows fit (with no mode line to cover a partial row, only whole rows are drawn: a row
     * below the window would land in the window under it). Dimmed numbers are lines 2-9 (8
     * digits) and 10 (2 digits). */
    PF_CHECK(count_color(d, PF_DISPLAY_GLYPH, 0x888888FF) == 8 + 2);
    for (i = 0; i < pf_display_count(d); i++) {
        if (it[i].kind == PF_DISPLAY_GLYPH && it[i].u.glyph.glyph == '(' && it[i].color == 0x000000FF) {
            PF_CHECK(NEAR(it[i].x, 45)); /* text starts after the gutter */
            break;
        }
    }
    pf_display_release(d);

    /* hl-line: one band on point's line, from the text start to the right edge. */
    pf_window_set_option(w, PF_WINDOW_LINE_NUMBERS, 0);
    pf_window_set_option(w, PF_WINDOW_HL_LINE, 1);
    d = frame_at(w, buf, point, 11); /* line 2: "{" */
    const pf_display_item *band = find_rect(d, 0xEEEEEEFF, 0);
    PF_CHECK(band && NEAR(band->x, 5) && NEAR(band->y, 20) && NEAR(band->u.rect.w, 395));
    PF_CHECK(find_rect(d, 0xEEEEEEFF, 1) == NULL);
    pf_display_release(d);
    pf_window_set_option(w, PF_WINDOW_HL_LINE, 0);

    /* show-paren: opener after point, closer before it, across lines, nesting, mismatches. */
    pf_window_set_option(w, PF_WINDOW_SHOW_PAREN, 1);
    d = frame_at(w, buf, point, 0); /* before "(" of "(a [b] c)" */
    const pf_display_item *p0 = find_rect(d, 0x00FF00FF, 0), *p1 = find_rect(d, 0x00FF00FF, 1);
    PF_CHECK(p0 && p1 && NEAR(p0->x, 5) && NEAR(p1->x, 5 + 80)); /* skips the nested [b] */
    pf_display_release(d);
    d = frame_at(w, buf, point, 6); /* after "]" */
    p0 = find_rect(d, 0x00FF00FF, 0);
    p1 = find_rect(d, 0x00FF00FF, 1);
    PF_CHECK(p0 && p1 && NEAR(p0->x, 5 + 50) && NEAR(p1->x, 5 + 30));
    pf_display_release(d);
    d = frame_at(w, buf, point, 10); /* "{" on line 2, "}" on line 3 */
    p1 = find_rect(d, 0x00FF00FF, 1);
    PF_CHECK(p1 && NEAR(p1->y, 40));
    pf_display_release(d);
    d = frame_at(w, buf, point, 14); /* "(x]": wrong closer */
    PF_CHECK(find_rect(d, 0x00FF00FF, 0) == NULL);
    PF_CHECK(find_rect(d, 0xFF00FFFF, 0) && find_rect(d, 0xFF00FFFF, 1));
    pf_display_release(d);
    d = frame_at(w, buf, point, 2); /* between "a" and " ": no bracket next to point */
    PF_CHECK(find_rect(d, 0x00FF00FF, 0) == NULL && find_rect(d, 0xFF00FFFF, 0) == NULL);
    pf_display_release(d);
    pf_buf_insert(buf, (size_t)pf_buf_chars(buf), "(", 1); /* unclosed at the end */
    d = frame_at(w, buf, point, (size_t)pf_buf_chars(buf) - 1);
    PF_CHECK(find_rect(d, 0xFF00FFFF, 0) && find_rect(d, 0xFF00FFFF, 1) == NULL);
    pf_display_release(d);

    pf_buf_free(buf);
    pf_window_free(w);
    pf_layout_cache_free(cache);
}

static void test_faces(void) {
    pf_layout_cache *cache = pf_layout_cache_new(fake, 256, 8);
    pf_window_style s = style();
    pf_window *w = pf_window_new(cache, &s);
    pf_window_set_size(w, 400, 100, 1);
    pf_handle buf = pf_buf_new("plain BOLD under", 16);
    uint32_t point = pf_buf_marker_new(buf, 16, 0);
    pf_window_set_buffer(w, buf, point);

    /* Face 20: red on yellow, font 9 (bold). Face 21: underlined, default color. */
    pf_face bold = {PF_FACE_HAS_FG | PF_FACE_HAS_BG, 0xFF0000FF, 0xFFFF00FF, 0, 9};
    pf_face under = {PF_FACE_UNDERLINE, 0, 0, 0, 0};
    pf_face_set(20, &bold);
    pf_face_set(21, &under);
    pf_props_put(pf_text_props(pf_handle_get(buf, PF_HANDLE_TEXT)), PF_PROP_FACE, 6, 10, 20);
    pf_props_put(pf_text_props(pf_handle_get(buf, PF_HANDLE_TEXT)), PF_PROP_FACE, 11, 16, 21);

    const pf_display *d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    size_t red = 0, bold_font = 0;
    const pf_display_item *yellow = NULL, *line = NULL;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *x = &pf_display_items(d)[i];
        if (x->kind == PF_DISPLAY_GLYPH && x->color == 0xFF0000FF) {
            red++;
            bold_font += x->u.glyph.font == 9;
        } else if (x->kind == PF_DISPLAY_RECT && x->color == 0xFFFF00FF) {
            yellow = x;
        } else if (x->kind == PF_DISPLAY_RECT && x->color == 0x000000FF && x->u.rect.h < 2) {
            line = x;
        }
    }
    PF_CHECK_EQ_SIZE(red, 4);          /* "BOLD" in the face's color... */
    PF_CHECK_EQ_SIZE(bold_font, 4);    /* ...shaped with the face's font */
    PF_CHECK(yellow && NEAR(yellow->x, 5 + 60) && NEAR(yellow->u.rect.w, 40));
    PF_CHECK(line && NEAR(line->x, 5 + 110) && NEAR(line->u.rect.w, 50)); /* default fg */
    pf_display_release(d);

    /* Changing a face, or a property alone, renders again. */
    PF_CHECK(pf_window_redisplay(w) == NULL);
    bold.fg = 0x00AA00FF;
    pf_face_set(20, &bold);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    pf_display_release(d);
    pf_props_put(pf_text_props(pf_handle_get(buf, PF_HANDLE_TEXT)), PF_PROP_FACE, 0, 5, 21);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    pf_display_release(d);

    /* Regression: the default face's background drew a full-width rect on every line. */
    d = frame_at(w, buf, point, 0);
    PF_CHECK(find_rect(d, 0xFFFFFFFF, 0) == NULL);
    pf_display_release(d);

    pf_buf_free(buf);
    pf_window_free(w);
    pf_layout_cache_free(cache);
}

/* A terminal window draws the cell grid: backgrounds, the cursor, glyphs in cell colors. */
static void test_terminal_window(void) {
    pf_layout_cache *cache = pf_layout_cache_new(fake, 256, 8);
    pf_window_style s = style();
    pf_window *w = pf_window_new(cache, &s);
    pf_window_set_size(w, 200, 100, 1);
    int rows, cols;
    pf_window_terminal_size(w, &rows, &cols);
    PF_CHECK(rows == 5 && cols == 20); /* 100 / 20 lines, 200 / 10 cells */

    pf_face regular = {0}, bold = {0};
    pf_face_set(20, &regular);
    pf_face_set(21, &bold);
    uint32_t faces[4] = {20, 21, 20, 21};
    pf_term *t = pf_term_new(rows, cols, 10);
    uint32_t ansi[16] = {0};
    ansi[1] = 0xCC0000;
    ansi[4] = 0x0000CC;
    pf_term_set_colors(t, 0x112233, 0xFFFFFF, ansi);
    const char *text = "ab\x1b[31mc\x1b[44m\x1b[1md\x1b[0m e";
    pf_term_feed(t, text, strlen(text));
    pf_window_set_terminal(w, t, faces);
    PF_CHECK(pf_window_terminal(w) == t);

    const pf_display *d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    const pf_display_item *it = pf_display_items(d);
    /* one background run for "d" (default backgrounds are not painted), the box cursor, 5 glyphs
     * (a b c d e) and the cursor cell's glyph, if any: the cursor is on the blank after "e" */
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_GLYPH), 5);
    float x_of[256];
    for (size_t i = 0; i < pf_display_count(d); i++) {
        if (it[i].kind == PF_DISPLAY_GLYPH) {
            x_of[it[i].u.glyph.glyph] = it[i].x;
            if (it[i].u.glyph.glyph == 'a') {
                PF_CHECK(it[i].color == 0x112233FF && NEAR(it[i].y, 12)); /* default fg, baseline */
            }
            if (it[i].u.glyph.glyph == 'c') {
                PF_CHECK(it[i].color == 0xCC0000FF);
            }
        }
    }
    PF_CHECK(NEAR(x_of['a'], 0) && NEAR(x_of['b'], 10) && NEAR(x_of['c'], 20) && NEAR(x_of['d'], 30) &&
             NEAR(x_of['e'], 50)); /* one cell per column, the blank between d and e kept */
    const pf_display_item *bg = find_rect(d, 0x0000CCFF, 0);
    PF_CHECK(bg && NEAR(bg->x, 30) && NEAR(bg->y, 0) && NEAR(bg->u.rect.w, 10) && NEAR(bg->u.rect.h, 20));
    const pf_display_item *cur = find_rect(d, 0xFF0000FF, 0); /* the cursor role's background */
    PF_CHECK(cur && NEAR(cur->x, 60) && NEAR(cur->y, 0) && NEAR(cur->u.rect.w, 10));
    float rect[4];
    PF_CHECK(pf_window_cursor_rect(w, rect) == 0 && NEAR(rect[0], 60) && NEAR(rect[3], 20));
    pf_display_release(d);

    /* nothing changed: no new frame; output, a resize or the cursor shape do */
    PF_CHECK(pf_window_redisplay(w) == NULL);
    pf_term_feed(t, "\r\nxy", 5);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_GLYPH), 7);
    pf_display_release(d);

    /* a hollow cursor outlines the cell (a non-selected window) */
    pf_window_set_option(w, PF_WINDOW_CURSOR, PF_CURSOR_HOLLOW);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL && count_color(d, PF_DISPLAY_RECT, 0xFF0000FF) == 4);
    pf_display_release(d);
    pf_window_set_option(w, PF_WINDOW_CURSOR, PF_CURSOR_NONE);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL && count_color(d, PF_DISPLAY_RECT, 0xFF0000FF) == 0 && pf_window_cursor_rect(w, rect) == -1);
    pf_display_release(d);

    /* box-drawing and block characters are rectangles that fill their cell, not font glyphs */
    pf_term_feed(t, "\x1b[2J\x1b[H\xe2\x94\x80\xe2\x94\x82\xe2\x94\xbc\xe2\x96\x88\xe2\x96\x84\xe2\x96\x91x", 7 + 3 * 6 + 1);
    pf_window_set_option(w, PF_WINDOW_CURSOR, PF_CURSOR_NONE);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL);
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_GLYPH), 1); /* only the x */
    {
        const pf_display_item *r = pf_display_items(d);
        size_t full = 0, wide_thin = 0, tall_thin = 0, half = 0, shade = 0;
        for (size_t i = 0; i < pf_display_count(d); i++) {
            if (r[i].kind != PF_DISPLAY_RECT) {
                continue;
            }
            float rw = r[i].u.rect.w, rh = r[i].u.rect.h;
            full += NEAR(rw, 10) && NEAR(rh, 20);
            wide_thin += NEAR(rw, 10) && NEAR(rh, 1); /* ─ and the horizontal of ┼, across their cells */
            tall_thin += NEAR(rw, 1) && NEAR(rh, 20) && NEAR(r[i].x, 14.5f) /* │ in the second cell */;
            half += NEAR(rw, 10) && NEAR(rh, 10) && NEAR(r[i].x, 40); /* ▄: the lower half of cell 4 */
            shade += (r[i].color & 0xFF) < 0xFF && r[i].color != 0 && NEAR(rw, 10) && NEAR(rh, 20);
        }
        PF_CHECK_EQ_SIZE(full, 2); /* █ and ░ (a full cell at partial alpha) */
        PF_CHECK_EQ_SIZE(wide_thin, 2);
        PF_CHECK_EQ_SIZE(half, 1);
        PF_CHECK_EQ_SIZE(shade, 1);
        PF_CHECK_EQ_SIZE(tall_thin, 1);
    }
    pf_display_release(d);

    /* a terminal window has no text positions */
    PF_CHECK(pf_window_pos_rect(w, 0, rect) == -1);

    /* back to a text window */
    pf_window_set_terminal(w, NULL, faces);
    PF_CHECK(pf_window_terminal(w) == NULL);
    pf_term_free(t);
    pf_window_free(w);
    pf_layout_cache_free(cache);
}

int main(void) {
    test_terminal_window();
    test_layout();
    test_window();
    test_editing_modes();
    test_faces();
    return PF_TEST_RESULT();
}
