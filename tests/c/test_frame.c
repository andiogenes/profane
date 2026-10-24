/* Frames: windows placed and composed, chrome (mode lines, fringes, dividers, tab bar), cursor
 * kinds, hidden windows and text scale, with a fake shaper: every character is a 10 pt glyph
 * whose id is its code point; fonts scale to "font + 100". */

#include <math.h>
#include <string.h>

#include "pf_buffer_ffi.h"
#include "pf_face.h"
#include "pf_frame.h"
#include "pf_layout.h"
#include "pf_test.h"

static float fake_shape(void *ctx, uint32_t font, const uint32_t *cps, size_t n, pf_shaped *out) {
    (void)ctx;
    for (size_t i = 0; i < n; i++) {
        pf_shaped_push(out, font, cps[i], 10.0f * (float)i, (uint32_t)i);
    }
    return 10.0f * (float)n;
}

static float fake_cell(void *ctx, uint32_t font) {
    (void)ctx, (void)font;
    return 10;
}

static int fake_metrics(void *ctx, uint32_t font, pf_font_metrics *out) {
    (void)ctx;
    float k = font > 100 ? 2 : 1; /* scaled fonts are twice as big */
    *out = (pf_font_metrics){15 * k, 5 * k, 0, 10 * k};
    return 0;
}

static uint32_t fake_scaled(void *ctx, uint32_t font, float factor) {
    (void)ctx, (void)factor;
    return font + 100;
}

static const pf_shaper fake = {NULL, fake_shape, fake_cell};
static const pf_font_source fonts = {NULL, fake_metrics, fake_scaled};

#define NEAR(a, b) (fabsf((a) - (b)) < 1e-3f)

#define BG 0xFFFFFFFFu
#define FG 0x000000FFu
#define CURSOR 0xFF0000FFu
#define BORDER 0x777777FFu
#define ML_BG 0xCCCCCCFFu
#define TAB_BG 0xDDDDDDFFu
#define MARK 0x555555FFu
#define REGION_BG 0xAACCFFFFu

static void set_face(uint32_t id, uint32_t flags, uint32_t fg, uint32_t bg) {
    pf_face f = {.flags = flags, .fg = fg, .bg = bg};
    pf_face_set(id, &f);
}

static void faces(void) {
    set_face(1, PF_FACE_HAS_FG | PF_FACE_HAS_BG, FG, BG);
    pf_face_set_role(PF_ROLE_DEFAULT, 1);
    set_face(2, PF_FACE_HAS_BG, 0, CURSOR);
    pf_face_set_role(PF_ROLE_CURSOR, 2);
    set_face(3, PF_FACE_HAS_FG, BORDER, 0);
    pf_face_set_role(PF_ROLE_VERTICAL_BORDER, 3);
    set_face(4, PF_FACE_HAS_FG, MARK, 0);
    pf_face_set_role(PF_ROLE_FRINGE, 4); /* continuation marks in its foreground */
    set_face(5, PF_FACE_HAS_BG, 0, REGION_BG);
    pf_face_set_role(PF_ROLE_REGION, 5);
    set_face(10, PF_FACE_HAS_BG, 0, ML_BG); /* mode line */
    set_face(11, PF_FACE_HAS_BG, 0, TAB_BG); /* tab bar */
}

/* The first glyph GLYPH in D, or NULL. */
static const pf_display_item *find_glyph(const pf_display *d, uint32_t glyph) {
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *it = &pf_display_items(d)[i];
        if (it->kind == PF_DISPLAY_GLYPH && it->u.glyph.glyph == glyph) {
            return it;
        }
    }
    return NULL;
}

static const pf_display_item *find_rect(const pf_display *d, uint32_t color) {
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *it = &pf_display_items(d)[i];
        if (it->kind == PF_DISPLAY_RECT && it->color == color) {
            return it;
        }
    }
    return NULL;
}

static size_t count_rects(const pf_display *d, uint32_t color) {
    size_t n = 0;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *it = &pf_display_items(d)[i];
        n += it->kind == PF_DISPLAY_RECT && it->color == color;
    }
    return n;
}

static void cps_of(const char *s, uint32_t *out, size_t *n) {
    for (*n = 0; s[*n]; (*n)++) {
        out[*n] = (unsigned char)s[*n];
    }
}

int main(void) {
    faces();
    pf_layout_cache *cache = pf_layout_cache_new(fake, 256, 8);
    pf_frame *f = pf_frame_new(cache, &fonts, 1);
    pf_frame_set_size(f, 400, 300, 2);

    pf_handle a = pf_buf_new("aaa", 3), b = pf_buf_new("bbb", 3);
    uint32_t pa = pf_buf_marker_new(a, 0, 0), pb = pf_buf_marker_new(b, 0, 0);
    pf_window *w1 = pf_frame_add_window(f, 7), *w2 = pf_frame_add_window(f, 8);
    PF_CHECK_EQ_SIZE(pf_frame_window_count(f), 2);
    PF_CHECK(pf_frame_window_tag(f, 1) == 8);
    pf_window_set_buffer(w1, a, pa);
    pf_window_set_buffer(w2, b, pb);
    pf_frame_place_window(f, w1, 0, 0, 400, 140, 1);
    pf_frame_place_window(f, w2, 0, 140, 400, 140, 1);
    pf_frame_select(f, w1);
    pf_window_set_option(w2, PF_WINDOW_CURSOR, PF_CURSOR_HOLLOW);

    /* Windows are rendered in their own coordinates and moved into place. */
    const pf_display *d = pf_frame_redisplay(f);
    PF_CHECK(d && pf_display_clear(d) == BG && NEAR(pf_display_width(d), 400));
    const pf_display_item *ga = find_glyph(d, 'a'), *gb = find_glyph(d, 'b');
    PF_CHECK(ga && NEAR(ga->y, 2 + 15));       /* pad_top + ascent */
    PF_CHECK(gb && NEAR(gb->y, 140 + 2 + 15)); /* in the second window */
    /* The selected window has a box cursor; the other a hollow one (four 1-pixel edges). */
    PF_CHECK_EQ_SIZE(count_rects(d, CURSOR), 1 + 4);
    float rect[4];
    PF_CHECK(pf_frame_cursor_rect(f, rect) == 0 && NEAR(rect[1], 2));
    pf_display_release(d);
    PF_CHECK(pf_frame_redisplay(f) == NULL); /* nothing changed */

    /* Only the edited window renders again; the other's last list is reused. */
    pf_buf_insert(b, 0, "c", 1);
    d = pf_frame_redisplay(f);
    PF_CHECK(d && find_glyph(d, 'a') && find_glyph(d, 'c'));
    pf_display_release(d);

    /* Mode line: a strip in its base face at the bottom of the window; fewer text lines. */
    PF_CHECK_EQ_SIZE(pf_window_body_lines(w1), 6); /* (140 - 2) / 20 */
    uint32_t cps[64];
    size_t n;
    cps_of("ML", cps, &n);
    pf_window_set_mode_line(w1, cps, n, NULL, 0, 10, 0);
    float ml = pf_window_mode_line_height(w1);
    PF_CHECK(NEAR(ml, 20 + 4)); /* one line plus padding */
    PF_CHECK(NEAR(pf_frame_strip_height(f, 10, 1), 20 + 4 + 2)); /* raised adds the box */
    PF_CHECK_EQ_SIZE(pf_window_body_lines(w1), 5);
    d = pf_frame_redisplay(f);
    const pf_display_item *mlr = find_rect(d, ML_BG), *m = find_glyph(d, 'M');
    PF_CHECK(mlr && NEAR(mlr->y, 140 - ml) && NEAR(mlr->u.rect.h, ml));
    PF_CHECK(m && m->y > 140 - ml && m->y < 140 && m->color == FG);
    pf_display_release(d);

    /* A divider on the right edge; long lines are clipped before it, never crossing it. */
    pf_window_set_edges(w1, 1, 1, 1);
    pf_buf_insert(a, 3, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", 59);
    d = pf_frame_redisplay(f);
    const pf_display_item *div = find_rect(d, BORDER);
    PF_CHECK(div && NEAR(div->x, 399) && NEAR(div->u.rect.w, 1));
    size_t glyphs_a = 0;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *it = &pf_display_items(d)[i];
        if (it->kind == PF_DISPLAY_GLYPH && it->u.glyph.glyph == 'a') {
            PF_CHECK(it->x + 10 <= 400 - 1 - 1 + 0.5f); /* inside the right fringe and divider */
            glyphs_a++;
        }
    }
    PF_CHECK_EQ_SIZE(glyphs_a, 39 + 1); /* x0 = 1: 39 cells fit before 398, + the cursor's */
    pf_display_release(d);

    /* Hidden windows (another tab) are not drawn. */
    pf_frame_place_window(f, w2, 0, 140, 400, 140, 0);
    d = pf_frame_redisplay(f);
    PF_CHECK(find_glyph(d, 'b') == NULL);
    pf_display_release(d);
    pf_frame_place_window(f, w2, 0, 140, 400, 140, 1);

    /* Text scale: buffer text in scaled fonts with taller lines; the mode line stays. */
    PF_CHECK(pf_frame_set_text_scale(f, w1, 2) == 0);
    d = pf_frame_redisplay(f);
    PF_CHECK(find_glyph(d, 'a')->u.glyph.font == 101);
    PF_CHECK(find_glyph(d, 'M')->u.glyph.font == 1);
    PF_CHECK(find_glyph(d, 'c')->u.glyph.font == 1); /* other windows unaffected */
    PF_CHECK_EQ_SIZE(pf_window_body_lines(w1), 2); /* (140 - 24 - 2) / 40 */
    pf_display_release(d);

    /* The tab bar across the top. */
    cps_of("tabs", cps, &n);
    pf_strip_run run = {0, 4, 1};
    pf_frame_set_tab_bar(f, cps, n, &run, 1, 11, 0);
    d = pf_frame_redisplay(f);
    const pf_display_item *tab = find_rect(d, TAB_BG), *t = find_glyph(d, 't');
    PF_CHECK(tab && NEAR(tab->y, 0) && NEAR(tab->u.rect.w, 400));
    PF_CHECK(t && t->y < 24);
    pf_display_release(d);

    /* Horizontal scrolling. Regression: with point past the right edge of a long line the
     * window did not scroll, and the cursor was drawn outside the window, over its neighbor. */
    pf_frame_set_text_scale(f, w1, 1);
    pf_frame_set_tab_bar(f, NULL, 0, NULL, 0, 0, 0);
    pf_frame_place_window(f, w1, 0, 0, 200, 140, 1);
    pf_window_set_edges(w1, 1, 1, 1); /* text area: x 1 .. 198, then fringe, divider */
    pf_buf_marker_set(a, pa, 62);     /* end of the 62-character line */
    d = pf_frame_redisplay(f);
    PF_CHECK(pf_frame_cursor_rect(f, rect) == 0);
    PF_CHECK(rect[0] >= 1 && rect[0] + rect[2] <= 198.5f); /* cursor inside the text area */
    PF_CHECK(pf_window_hscroll(w1) > 0);
    for (size_t i = 0; i < pf_display_count(d); i++) {
        const pf_display_item *it = &pf_display_items(d)[i];
        if (it->kind == PF_DISPLAY_GLYPH && it->u.glyph.glyph == 'a') {
            PF_CHECK(it->x >= 1 - 0.5f && it->x + 10 <= 198.5f); /* clipped on both sides */
        }
        if (it->kind == PF_DISPLAY_RECT && it->color == CURSOR) {
            PF_CHECK(it->x >= 0 && it->x + it->u.rect.w <= 200);
        }
    }
    /* Text continues to the left: a mark in the left fringe. */
    PF_CHECK(find_rect(d, MARK) && NEAR(find_rect(d, MARK)->x, 0));
    pf_display_release(d);
    pf_buf_marker_set(a, pa, 0); /* back at the start: no scroll */
    d = pf_frame_redisplay(f);
    PF_CHECK(pf_window_hscroll(w1) == 0);
    const pf_display_item *mark = find_rect(d, MARK); /* continues to the right */
    PF_CHECK(mark && NEAR(mark->x, 198));

    pf_display_release(d);
    /* scroll-left sets a minimum the automatic scrolling keeps. */
    pf_window_set_min_hscroll(w1, 100);
    d = pf_frame_redisplay(f);
    PF_CHECK(NEAR(pf_window_hscroll(w1), 100));
    const pf_display_item *c = find_rect(d, CURSOR); /* the first is w1's when it has one */
    PF_CHECK(!c || c->y >= 140); /* point is off to the left: no cursor drawn in w1 */
    pf_display_release(d);
    pf_window_set_min_hscroll(w1, 0);

    /* The active region is drawn under the text, in the window it is set on. */
    pf_window_set_region(w1, 1, 3); /* "aaa": the 2nd and 3rd characters */
    d = pf_frame_redisplay(f);
    const pf_display_item *rg = find_rect(d, REGION_BG);
    PF_CHECK(rg && NEAR(rg->u.rect.w, 20) && NEAR(rg->y, 2)); /* below the top pad */
    const pf_display_item *first = find_glyph(d, 'a');
    PF_CHECK(rg && first && rg->x >= first->x + 9.9f); /* starts after the first character */
    pf_display_release(d);
    pf_window_set_region(w1, 2, 2); /* empty: none */
    d = pf_frame_redisplay(f);
    PF_CHECK(find_rect(d, REGION_BG) == NULL);
    pf_display_release(d);
    pf_window_set_region(w1, 3, 0); /* reversed and reaching the end: still drawn */
    d = pf_frame_redisplay(f);
    PF_CHECK(find_rect(d, REGION_BG) != NULL);
    pf_display_release(d);
    pf_window_set_region(w1, 0, 0);
    d = pf_frame_redisplay(f);
    pf_display_release(d);

    /* Native-view windows: the body is left empty and reported to the shell. */
    uint64_t gen0 = pf_frame_native_generation(f);
    PF_CHECK_EQ_SIZE(pf_frame_native_count(f), 0);
    pf_window_set_edges(w2, 4, 4, 1);
    PF_CHECK(pf_frame_set_window_native(f, w2, 1) == 0);
    PF_CHECK(pf_frame_native_generation(f) != gen0);
    d = pf_frame_redisplay(f);
    PF_CHECK(d != NULL);
    PF_CHECK(find_glyph(d, 'b') == NULL); /* no text from w2 (w1 shows 'a' only) */
    PF_CHECK(find_glyph(d, 'a') != NULL);
    pf_display_release(d);
    PF_CHECK_EQ_SIZE(pf_frame_native_count(f), 1);
    pf_native_placement np;
    PF_CHECK(pf_frame_native_get(f, 0, &np) == 0 && np.tag == 8 && np.kind == 1 && np.shown);
    float mlh = pf_window_mode_line_height(w2);
    PF_CHECK(NEAR(np.x, 0) && NEAR(np.y, 140) && NEAR(np.w, 399) && NEAR(np.h, 140 - mlh));
    PF_CHECK(pf_frame_native_get(f, 1, &np) == -1);
    uint64_t gen1 = pf_frame_native_generation(f);
    pf_frame_place_window(f, w2, 0, 140, 400, 100, 1);
    PF_CHECK(pf_frame_native_generation(f) != gen1); /* moving or resizing re-places the view */
    pf_frame_place_window(f, w2, 0, 140, 400, 100, 0);
    PF_CHECK(pf_frame_native_get(f, 0, &np) == 0 && !np.shown);
    pf_frame_place_window(f, w2, 0, 140, 400, 140, 1);
    PF_CHECK(pf_frame_set_window_native(f, w2, 0) == 0 && pf_frame_native_count(f) == 0);
    d = pf_frame_redisplay(f);
    PF_CHECK(find_glyph(d, 'b') != NULL); /* a text window again */
    pf_display_release(d);
    pf_frame_set_window_native(f, w2, 1);

    /* Removing a window. */
    PF_CHECK(pf_frame_remove_window(f, w2) == 0);
    PF_CHECK(pf_frame_remove_window(f, w2) == -1);
    d = pf_frame_redisplay(f);
    PF_CHECK(find_glyph(d, 'c') == NULL);
    pf_display_release(d);
    PF_CHECK_EQ_SIZE(pf_frame_native_count(f), 0); /* a removed native window is gone */

    pf_frame_free(f);
    pf_layout_cache_free(cache);
    return PF_TEST_RESULT();
}
