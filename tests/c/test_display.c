/* Display lists: building, freezing, sharing across threads by refcount. */

#include <pthread.h>

#include "pf_display.h"
#include "pf_test.h"

static void *release_elsewhere(void *arg) {
    pf_display_release(arg);
    return NULL;
}

static void test_clip(void) {
    pf_display *a = pf_display_new(50, 50, 1, 0);
    pf_display_clip(a, 5, 6, 20, -3); /* a negative size is an empty clip */
    pf_display_rect(a, 0, 0, 40, 40, 0xFF0000FF);
    pf_display_unclip(a);
    const pf_display *src = pf_display_finish(a);
    PF_CHECK_EQ_SIZE(pf_display_count(src), 3);
    const pf_display_item *it = pf_display_items(src);
    PF_CHECK(it[0].kind == PF_DISPLAY_CLIP && it[0].x == 5 && it[0].y == 6);
    PF_CHECK(it[0].u.rect.w == 20 && it[0].u.rect.h == 0);
    PF_CHECK(it[2].kind == PF_DISPLAY_UNCLIP);

    /* Composing a window into a frame moves its clip with it. */
    pf_display *f = pf_display_new(200, 200, 1, 0);
    pf_display_append(f, src, 100, 50);
    const pf_display *frame = pf_display_finish(f);
    it = pf_display_items(frame);
    PF_CHECK(it[0].kind == PF_DISPLAY_CLIP && it[0].x == 105 && it[0].y == 56);
    PF_CHECK(it[1].kind == PF_DISPLAY_RECT && it[1].x == 100 && it[1].y == 50);
    pf_display_release(frame);
    pf_display_release(src);
}

int main(void) {
    test_clip();
    pf_display *d = pf_display_new(800, 600, 2, 0xFFFFFFFF);
    pf_display_rect(d, 0, 20, 800, 18, 0xF0F0F0FF);
    pf_display_rect(d, 0, 0, 0, 10, 0x000000FF);  /* empty: dropped */
    pf_display_rect(d, 0, 0, 10, 10, 0x12345600); /* invisible: dropped */
    for (int i = 0; i < 1000; i++) {
        pf_display_glyph(d, 1, (uint32_t)(36 + i % 26), 8.0f + 8.4f * (float)i, 34, 0x000000FF);
    }
    const pf_display *f = pf_display_finish(d);

    PF_CHECK(pf_display_width(f) == 800 && pf_display_height(f) == 600);
    PF_CHECK(pf_display_scale(f) == 2);
    PF_CHECK(pf_display_clear(f) == 0xFFFFFFFF);
    PF_CHECK_EQ_SIZE(pf_display_count(f), 1001);

    const pf_display_item *items = pf_display_items(f);
    PF_CHECK(items[0].kind == PF_DISPLAY_RECT && items[0].u.rect.w == 800 && items[0].y == 20);
    PF_CHECK(items[1].kind == PF_DISPLAY_GLYPH && items[1].u.glyph.glyph == 36);
    PF_CHECK(items[1000].x > 8000 && items[1000].u.glyph.font == 1);

    /* The render thread may drop the last reference. */
    pf_display_retain(f);
    pthread_t th;
    pthread_create(&th, NULL, release_elsewhere, (void *)f);
    pthread_join(th, NULL);
    PF_CHECK_EQ_SIZE(pf_display_count(f), 1001);
    pf_display_release(f);
    return PF_TEST_RESULT();
}
