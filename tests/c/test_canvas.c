/* Canvases and pop-up surfaces: draw ops, hit regions, text, and the overlay a frame composes.
 * Fake shaper: 10 pt per character, glyph id = code point; the default font is 15/5 (20 pt). */

#include <math.h>

#include "pf_canvas.h"
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

static const pf_shaper fake = {NULL, fake_shape, fake_cell};

#define NEAR(a, b) (fabsf((a) - (b)) < 1e-3f)

static size_t count_kind(const pf_display *d, uint32_t kind) {
    size_t n = 0;
    for (size_t i = 0; i < pf_display_count(d); i++) {
        n += pf_display_items(d)[i].kind == kind;
    }
    return n;
}

int main(void) {
    pf_face face = {.flags = PF_FACE_HAS_FG, .fg = 0x112233FFu};
    pf_face_set(1, &face);
    pf_face_set_role(PF_ROLE_DEFAULT, 1);

    pf_layout_cache *cache = pf_layout_cache_new(fake, 64, 8);
    pf_frame *f = pf_frame_new(cache, NULL, 1);
    pf_frame_set_size(f, 400, 300, 2);

    /* Ops become display items, moved by the surface's position. */
    pf_canvas *c = pf_canvas_new(100, 50);
    uint64_t v0 = pf_canvas_version(c);
    pf_canvas_shadow(c, 0, 4, 100, 50, 6, 8, 0x00000040u);
    pf_canvas_fill_round_rect(c, 0, 0, 100, 50, 6, 0xFFFFFFFFu);
    pf_canvas_stroke_round_rect(c, 0, 0, 100, 50, 6, 1, 0x888888FFu);
    pf_canvas_fill_rect(c, 10, 10, 20, 2, 0xFF0000FFu);
    uint32_t hello[] = {'h', 'i'};
    pf_canvas_text(c, 5, 20, hello, 2, 1, 0);
    PF_CHECK(pf_canvas_version(c) != v0);

    /* Nothing is shown until a pop-up is. */
    const pf_display *none = pf_frame_redisplay_overlay(f);
    PF_CHECK(none == NULL || pf_display_count(none) == 0);
    pf_display_release(none);
    PF_CHECK(pf_frame_redisplay_overlay(f) == NULL);

    pf_frame_popup_show(f, c, 40, 30);
    const pf_display *d = pf_frame_redisplay_overlay(f);
    PF_CHECK(d != NULL);
    PF_CHECK(pf_display_clear(d) == 0 && NEAR(pf_display_width(d), 400));
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_SHADOW), 1);
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_ROUND_RECT), 2);
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_RECT), 1);
    PF_CHECK_EQ_SIZE(count_kind(d, PF_DISPLAY_GLYPH), 2);
    const pf_display_item *it = pf_display_items(d);
    PF_CHECK(it[0].kind == PF_DISPLAY_SHADOW && NEAR(it[0].x, 40) && NEAR(it[0].y, 34));
    PF_CHECK(NEAR(it[0].u.round.extra, 8));
    PF_CHECK(it[1].kind == PF_DISPLAY_ROUND_RECT && NEAR(it[1].u.round.extra, 0));
    PF_CHECK(NEAR(it[2].u.round.extra, 1));
    PF_CHECK(it[3].kind == PF_DISPLAY_RECT && NEAR(it[3].x, 50) && NEAR(it[3].y, 40));
    PF_CHECK(it[4].kind == PF_DISPLAY_GLYPH && it[4].u.glyph.glyph == 'h' && NEAR(it[4].x, 45));
    PF_CHECK(NEAR(it[4].y, 30 + 20 + 15) && it[4].color == 0x112233FFu); /* baseline: top + ascent */
    PF_CHECK(NEAR(it[5].x, 55));
    pf_display_release(d);

    /* Unchanged: no new overlay. Changed canvas, moved pop-up: a new one. */
    PF_CHECK(pf_frame_redisplay_overlay(f) == NULL);
    pf_canvas_fill_rect(c, 0, 0, 1, 1, 0x000000FFu);
    d = pf_frame_redisplay_overlay(f);
    PF_CHECK(d != NULL);
    pf_display_release(d);
    pf_frame_popup_show(f, c, 41, 30);
    d = pf_frame_redisplay_overlay(f);
    PF_CHECK(d != NULL && NEAR(pf_display_items(d)[0].x, 41));
    pf_display_release(d);
    float px, py;
    PF_CHECK(pf_frame_popup_shown(f, c, &px, &py) && NEAR(px, 41));

    /* Text color override; extent from the shaper and metrics. */
    pf_canvas_clear(c);
    pf_canvas_text(c, 0, 0, hello, 2, 1, 0xFF00FFFFu);
    d = pf_frame_redisplay_overlay(f);
    PF_CHECK_EQ_SIZE(pf_display_count(d), 2);
    PF_CHECK(pf_display_items(d)[0].color == 0xFF00FFFFu);
    pf_display_release(d);
    float w, h;
    pf_frame_text_extent(f, hello, 2, 1, &w, &h);
    PF_CHECK(NEAR(w, 20) && NEAR(h, 20));

    /* Lines are rects. */
    pf_canvas_clear(c);
    pf_canvas_line(c, 10, 5, 50, 5, 2, 0x000000FFu);
    pf_canvas_line(c, 7, 10, 7, 40, 4, 0x000000FFu);
    d = pf_frame_redisplay_overlay(f);
    PF_CHECK_EQ_SIZE(pf_display_count(d), 2);
    PF_CHECK(NEAR(pf_display_items(d)[0].y, 30 + 5 - 1));
    PF_CHECK(NEAR(pf_display_items(d)[0].u.rect.w, 40) && NEAR(pf_display_items(d)[0].u.rect.h, 2));
    PF_CHECK(NEAR(pf_display_items(d)[1].u.rect.w, 4) && NEAR(pf_display_items(d)[1].u.rect.h, 30));
    pf_display_release(d);

    /* Hit regions: topmost wins; coordinates are the frame's, through the pop-up's position. */
    pf_canvas_clear(c);
    pf_canvas_add_hit(c, 0, 0, 100, 50, 1, 0);
    pf_canvas_add_hit(c, 10, 10, 20, 20, 2, 1);
    pf_canvas *hit = NULL;
    int cursor = -1;
    PF_CHECK(pf_frame_hit_test(f, 41 + 15, 30 + 15, &hit, &cursor) == 2 && hit == c && cursor == 1);
    PF_CHECK(pf_frame_hit_test(f, 41 + 50, 30 + 40, &hit, &cursor) == 1 && cursor == 0);
    PF_CHECK(pf_frame_hit_test(f, 5, 5, &hit, &cursor) == -1);
    PF_CHECK(pf_canvas_hit_test(c, 100, 10, NULL) == -1); /* right edge is outside */

    /* Pop-ups stack: the later one is on top, for drawing and hits. */
    pf_canvas *top = pf_canvas_new(30, 30);
    pf_canvas_add_hit(top, 0, 0, 30, 30, 9, 0);
    pf_frame_popup_show(f, top, 41 + 10, 30 + 10);
    PF_CHECK(pf_frame_hit_test(f, 41 + 15, 30 + 15, &hit, &cursor) == 9 && hit == top);
    PF_CHECK(pf_frame_popup_hide(f, top) == 0);
    pf_canvas_free(top);
    PF_CHECK(pf_frame_popup_hide(f, c) == 0 && pf_frame_popup_hide(f, c) == -1);
    d = pf_frame_redisplay_overlay(f);
    PF_CHECK(d != NULL && pf_display_count(d) == 0); /* hiding redraws the overlay, now empty */
    pf_display_release(d);

    pf_canvas_free(c);
    pf_frame_free(f);
    pf_layout_cache_free(cache);
    return PF_TEST_RESULT();
}
