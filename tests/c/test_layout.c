/* Layout cache and window display with a fake monospace shaper: every character is a 10 pt
 * glyph whose id is its code point, except "fi", which becomes one ligature glyph (id 0xFB01). */

#include <math.h>
#include <string.h>

#include "pf_buffer_ffi.h"
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

static pf_window_style style(void) {
    return (pf_window_style){
        .font = 1, .ascent = 12, .descent = 4, .line_height = 20, .cell_width = 10,
        .pad_left = 5, .pad_top = 0,
        .background = 0xFFFFFFFF, .foreground = 0x000000FF, .cursor = 0xFF0000FF};
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

    /* A killed buffer shows an empty window instead of crashing. */
    pf_buf_free(buf);
    pf_window_invalidate(w);
    d = pf_window_redisplay(w);
    PF_CHECK(d != NULL && pf_display_count(d) == 0);
    pf_display_release(d);

    pf_window_free(w);
    pf_layout_cache_free(cache);
}

int main(void) {
    test_layout();
    test_window();
    return PF_TEST_RESULT();
}
