#ifndef PF_CANVAS_FFI_H
#define PF_CANVAS_FFI_H

#include <stddef.h>
#include <stdint.h>

#include "pf_canvas.h"
#include "pf_handles.h"

/* Canvases and pop-up surfaces for Scheme's `foreign-procedure`, as handles (see
 * pf_buffer_ffi.h for conventions). Colors are sRGB 0xRRGGBBAA. Main thread only. Calls given
 * a bad handle return -2. */

pf_handle pf_cvs_new(float width, float height); /* 0 on failure */
/* Hides the canvas wherever it is shown (in the selected frame) and frees it. */
int pf_cvs_free(pf_handle canvas);
int pf_cvs_set_size(pf_handle canvas, float width, float height);
double pf_cvs_width(pf_handle canvas);
double pf_cvs_height(pf_handle canvas);
int pf_cvs_clear(pf_handle canvas);
int pf_cvs_fill_rect(pf_handle canvas, float x, float y, float w, float h, uint32_t color);
int pf_cvs_fill_round_rect(pf_handle canvas, float x, float y, float w, float h, float radius,
                           uint32_t color);
int pf_cvs_stroke_round_rect(pf_handle canvas, float x, float y, float w, float h, float radius,
                             float line, uint32_t color);
int pf_cvs_shadow(pf_handle canvas, float x, float y, float w, float h, float radius, float blur,
                  uint32_t color);
int pf_cvs_line(pf_handle canvas, float x0, float y0, float x1, float y1, float line,
                uint32_t color);
/* COLOR 0: the face's foreground. */
int pf_cvs_text(pf_handle canvas, float x, float y, const char *utf8, size_t len, uint32_t face,
                uint32_t color);
int pf_cvs_add_hit(pf_handle canvas, float x, float y, float w, float h, uint32_t id, int cursor);
/* Region id at (X, Y) in the canvas's own coordinates, or -1. */
int64_t pf_cvs_hit_test(pf_handle canvas, float x, float y);

/* Text size in FACE's font, as pop-ups draw it (selected frame). */
double pf_cvs_text_width(pf_handle frame, const char *utf8, size_t len, uint32_t face);
double pf_cvs_text_height(pf_handle frame, uint32_t face);

/* ---- pop-up surfaces on the overlay layer (selected frame or the given one) ---- */
int pf_cvs_popup_show(pf_handle frame, pf_handle canvas, float x, float y);
int pf_cvs_popup_hide(pf_handle frame, pf_handle canvas);
int pf_cvs_popup_shown(pf_handle frame, pf_handle canvas);
/* Topmost pop-up region at (X, Y) in frame coordinates: its id, or -1. The canvas it is in and
 * its cursor shape are then pf_cvs_hit_canvas and pf_cvs_hit_cursor. */
int64_t pf_cvs_frame_hit(pf_handle frame, float x, float y);
pf_handle pf_cvs_hit_canvas(void);
int pf_cvs_hit_cursor(void);
/* Renders the overlay as the shell would; returns its item count, -1 if nothing changed. */
int64_t pf_cvs_overlay_redisplay(pf_handle frame);

#endif
