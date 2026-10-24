#ifndef PF_CANVAS_H
#define PF_CANVAS_H

#include <stddef.h>
#include <stdint.h>

#include "pf_display.h"
#include "pf_layout.h"
#include "pf_strip.h"

/* A canvas: a retained list of draw ops that Scheme builds with (profane canvas) and the
 * frame composes onto the overlay layer as a pop-up surface. Coordinates are points, origin
 * top-left of the canvas. Ops draw in order; hit regions are tested last-added first. A canvas
 * redraws only when its version changed. Main thread only; portable.
 *
 * Not yet: paths and bezier curves, images, clip and transform (they land with the widget
 * toolkit, M7), and canvas windows and inline canvases (hosts besides pop-ups). */

typedef struct pf_canvas pf_canvas;

pf_canvas *pf_canvas_new(float width, float height);
void pf_canvas_free(pf_canvas *c);

void pf_canvas_set_size(pf_canvas *c, float width, float height);
float pf_canvas_width(const pf_canvas *c);
float pf_canvas_height(const pf_canvas *c);

/* Bumped by every change; the frame redraws a shown canvas when it moves. */
uint64_t pf_canvas_version(const pf_canvas *c);

/* Drops every op and hit region. */
void pf_canvas_clear(pf_canvas *c);

void pf_canvas_fill_rect(pf_canvas *c, float x, float y, float w, float h, uint32_t color);
void pf_canvas_fill_round_rect(pf_canvas *c, float x, float y, float w, float h, float radius,
                               uint32_t color);
/* An outline LINE points wide, inside the rect. */
void pf_canvas_stroke_round_rect(pf_canvas *c, float x, float y, float w, float h, float radius,
                                 float line, uint32_t color);
void pf_canvas_shadow(pf_canvas *c, float x, float y, float w, float h, float radius, float blur,
                      uint32_t color);
/* A horizontal or vertical line of width LINE from (X0, Y0) to (X1, Y1) (others: the box that
 * contains them, so no diagonals yet). */
void pf_canvas_line(pf_canvas *c, float x0, float y0, float x1, float y1, float line,
                    uint32_t color);
/* Text with its top-left at (X, Y), in face FACE's font and foreground; COLOR (alpha > 0)
 * overrides the foreground. */
void pf_canvas_text(pf_canvas *c, float x, float y, const uint32_t *cps, size_t n, uint32_t face,
                    uint32_t color);

/* Hit regions: ID is Scheme's, CURSOR a cursor shape (0 arrow, 1 pointer, 2 text). */
void pf_canvas_add_hit(pf_canvas *c, float x, float y, float w, float h, uint32_t id, int cursor);
/* The topmost region containing (X, Y) (canvas coordinates): its id, or -1. */
int64_t pf_canvas_hit_test(const pf_canvas *c, float x, float y, int *cursor);

/* What drawing needs beyond the canvas: text shaping and fonts. */
typedef struct pf_canvas_env {
    pf_layout_cache *cache;
    const pf_font_source *fonts; /* may be NULL */
    uint32_t default_font;
} pf_canvas_env;

/* Size of CPS in FACE's font: advance width and line height. */
void pf_canvas_text_extent(const pf_canvas_env *env, const uint32_t *cps, size_t n, uint32_t face,
                           float *width, float *height);

/* Appends C's ops to D, moved by (DX, DY). */
void pf_canvas_render(const pf_canvas *c, pf_display *d, const pf_canvas_env *env, float dx,
                      float dy);

#endif
