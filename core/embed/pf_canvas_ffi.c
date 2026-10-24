#include "pf_canvas_ffi.h"

#include <stdlib.h>

#include "pf_frame.h"
#include "pf_utf8.h"
#include "pf_window_ffi.h"

enum { INVALID = -2 };

static pf_canvas *canvas_of(pf_handle h) {
    return pf_handle_get(h, PF_HANDLE_CANVAS);
}

static pf_frame *frame_of(pf_handle h) {
    return pf_handle_get(h, PF_HANDLE_FRAME);
}

/* Decodes UTF8 into a fresh array of code points (raw bytes as U+FFFD); *N gets the count. */
static uint32_t *decode(const char *utf8, size_t len, size_t *n) {
    const unsigned char *p = (const unsigned char *)utf8;
    uint32_t *cps = malloc((len ? len : 1) * sizeof *cps);
    size_t k = 0;
    for (size_t i = 0; cps && i < len;) {
        size_t u = pf_utf8_unit_len(p + i, len - i);
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
    *n = k;
    return cps;
}

/* Freeing hides the canvas in the selected frame; Scheme hides it elsewhere first. */
pf_handle pf_cvs_new(float width, float height) {
    pf_canvas *c = pf_canvas_new(width, height);
    pf_handle h = pf_handle_new(PF_HANDLE_CANVAS, c);
    if (!h) {
        pf_canvas_free(c);
    }
    return h;
}

int pf_cvs_free(pf_handle canvas) {
    pf_canvas *c = pf_handle_free(canvas, PF_HANDLE_CANVAS);
    if (!c) {
        return INVALID;
    }
    pf_frame *f = frame_of(pf_frm_selected());
    if (f) {
        pf_frame_popup_hide(f, c);
    }
    pf_canvas_free(c);
    return 0;
}

int pf_cvs_set_size(pf_handle canvas, float width, float height) {
    pf_canvas *c = canvas_of(canvas);
    if (!c) {
        return INVALID;
    }
    pf_canvas_set_size(c, width, height);
    return 0;
}

double pf_cvs_width(pf_handle canvas) {
    pf_canvas *c = canvas_of(canvas);
    return c ? pf_canvas_width(c) : INVALID;
}

double pf_cvs_height(pf_handle canvas) {
    pf_canvas *c = canvas_of(canvas);
    return c ? pf_canvas_height(c) : INVALID;
}

#define WITH_CANVAS(call)                                                                          \
    do {                                                                                           \
        pf_canvas *c = canvas_of(canvas);                                                          \
        if (!c) {                                                                                  \
            return INVALID;                                                                        \
        }                                                                                          \
        call;                                                                                      \
        return 0;                                                                                  \
    } while (0)

int pf_cvs_clear(pf_handle canvas) {
    WITH_CANVAS(pf_canvas_clear(c));
}

int pf_cvs_fill_rect(pf_handle canvas, float x, float y, float w, float h, uint32_t color) {
    WITH_CANVAS(pf_canvas_fill_rect(c, x, y, w, h, color));
}

int pf_cvs_fill_round_rect(pf_handle canvas, float x, float y, float w, float h, float radius,
                           uint32_t color) {
    WITH_CANVAS(pf_canvas_fill_round_rect(c, x, y, w, h, radius, color));
}

int pf_cvs_stroke_round_rect(pf_handle canvas, float x, float y, float w, float h, float radius,
                             float line, uint32_t color) {
    WITH_CANVAS(pf_canvas_stroke_round_rect(c, x, y, w, h, radius, line, color));
}

int pf_cvs_shadow(pf_handle canvas, float x, float y, float w, float h, float radius, float blur,
                  uint32_t color) {
    WITH_CANVAS(pf_canvas_shadow(c, x, y, w, h, radius, blur, color));
}

int pf_cvs_line(pf_handle canvas, float x0, float y0, float x1, float y1, float line,
                uint32_t color) {
    WITH_CANVAS(pf_canvas_line(c, x0, y0, x1, y1, line, color));
}

int pf_cvs_add_hit(pf_handle canvas, float x, float y, float w, float h, uint32_t id, int cursor) {
    WITH_CANVAS(pf_canvas_add_hit(c, x, y, w, h, id, cursor));
}

int pf_cvs_text(pf_handle canvas, float x, float y, const char *utf8, size_t len, uint32_t face,
                uint32_t color) {
    pf_canvas *c = canvas_of(canvas);
    if (!c) {
        return INVALID;
    }
    size_t n;
    uint32_t *cps = decode(utf8, len, &n);
    if (!cps) {
        return -1;
    }
    pf_canvas_text(c, x, y, cps, n, face, color);
    free(cps);
    return 0;
}

int64_t pf_cvs_hit_test(pf_handle canvas, float x, float y) {
    pf_canvas *c = canvas_of(canvas);
    return c ? pf_canvas_hit_test(c, x, y, NULL) : INVALID;
}

double pf_cvs_text_width(pf_handle frame, const char *utf8, size_t len, uint32_t face) {
    pf_frame *f = frame_of(frame);
    size_t n;
    uint32_t *cps = f ? decode(utf8, len, &n) : NULL;
    if (!cps) {
        return INVALID;
    }
    float w;
    pf_frame_text_extent(f, cps, n, face, &w, NULL);
    free(cps);
    return w;
}

double pf_cvs_text_height(pf_handle frame, uint32_t face) {
    pf_frame *f = frame_of(frame);
    if (!f) {
        return INVALID;
    }
    float h;
    pf_frame_text_extent(f, NULL, 0, face, NULL, &h);
    return h;
}

int pf_cvs_popup_show(pf_handle frame, pf_handle canvas, float x, float y) {
    pf_frame *f = frame_of(frame);
    pf_canvas *c = canvas_of(canvas);
    if (!f || !c) {
        return INVALID;
    }
    pf_frame_popup_show(f, c, x, y);
    return 0;
}

int pf_cvs_popup_hide(pf_handle frame, pf_handle canvas) {
    pf_frame *f = frame_of(frame);
    pf_canvas *c = canvas_of(canvas);
    return f && c ? pf_frame_popup_hide(f, c) : INVALID;
}

int pf_cvs_popup_shown(pf_handle frame, pf_handle canvas) {
    pf_frame *f = frame_of(frame);
    pf_canvas *c = canvas_of(canvas);
    return f && c ? pf_frame_popup_shown(f, c, NULL, NULL) : INVALID;
}

static pf_canvas *hit_canvas;
static int hit_cursor;

int64_t pf_cvs_frame_hit(pf_handle frame, float x, float y) {
    pf_frame *f = frame_of(frame);
    if (!f) {
        return INVALID;
    }
    hit_canvas = NULL;
    hit_cursor = 0;
    return pf_frame_hit_test(f, x, y, &hit_canvas, &hit_cursor);
}

pf_handle pf_cvs_hit_canvas(void) {
    return hit_canvas ? pf_handle_of(hit_canvas, PF_HANDLE_CANVAS) : 0;
}

int pf_cvs_hit_cursor(void) {
    return hit_cursor;
}

int64_t pf_cvs_overlay_redisplay(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    if (!f) {
        return INVALID;
    }
    const pf_display *d = pf_frame_redisplay_overlay(f);
    if (!d) {
        return -1;
    }
    int64_t n = (int64_t)pf_display_count(d);
    pf_display_release(d);
    return n;
}
