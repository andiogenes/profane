#ifndef PF_RENDERER_H
#define PF_RENDERER_H

#include <stdint.h>

#include "pf_display.h"

/* The renderer interface everything draws through. The implementation (Metal, in the platform
 * shell) owns a render thread driven by the display link: each frame it takes the newest
 * submitted display list per layer, redraws only layers whose list changed, and presents.
 * Creating a renderer is platform-specific; submitting is not. */

typedef struct pf_renderer pf_renderer;

/* ProfaneView's Metal layers, bottom to top. Native views (web, PDF, ...) sit between them,
 * so pop-ups always go on the overlay. */
typedef enum pf_layer {
    PF_LAYER_BASE = 0,
    PF_LAYER_OVERLAY = 1,
    PF_LAYER_COUNT
} pf_layer;

/* Hands DISPLAY to the render thread (taking a reference); a list not yet drawn is replaced
 * by a newer one. Any thread. */
void pf_renderer_submit(pf_renderer *r, pf_layer layer, const pf_display *display);

/* Frames presented on screen so far (all layers). */
uint64_t pf_renderer_presented_frames(const pf_renderer *r);

#endif
