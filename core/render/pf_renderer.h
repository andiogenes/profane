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

/* ---- input latency ----
 * Call before submitting the frame that answers an input event; EVENT_TIME is when the event
 * happened (seconds on the host clock, e.g. NSEvent.timestamp). The renderer then records, for
 * that frame, the times it was submitted, committed to the GPU and presented. */
void pf_renderer_mark_input(pf_renderer *r, double event_time);

/* Milliseconds from the input event to each stage: p50, p95 and max over recent samples.
 *   submit:  display list handed to the renderer (input handling, command, redisplay)
 *   commit:  frame encoded and committed (the software pipeline; the <8 ms target)
 *   present: presented handler ran (adds waiting for the display's refresh and compositing) */
typedef struct pf_latency_stats {
    size_t samples;
    double submit[3], commit[3], present[3];
} pf_latency_stats;

pf_latency_stats pf_renderer_latency(const pf_renderer *r);
void pf_renderer_latency_reset(pf_renderer *r);

#endif
