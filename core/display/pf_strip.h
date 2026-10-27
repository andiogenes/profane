#ifndef PF_STRIP_H
#define PF_STRIP_H

#include <stddef.h>
#include <stdint.h>

#include "pf_display.h"
#include "pf_font.h"
#include "pf_layout.h"

/* Fonts as the display engine needs them beyond shaping: metrics, and copies at another size
 * (text scale). Implemented by the platform; a NULL source or member (headless frames, tests)
 * falls back to the fixed shaper's metrics and no scaling. */
typedef struct pf_font_source {
    void *ctx;
    int (*metrics)(void *ctx, uint32_t font, pf_font_metrics *out); /* 0, or -1 if unknown */
    uint32_t (*scaled)(void *ctx, uint32_t font, float factor);     /* 0 on failure */
} pf_font_source;

pf_font_metrics pf_font_source_metrics(const pf_font_source *src, uint32_t font);
/* FONT at FACTOR times its size; FONT itself for a factor of 1 or when scaling is unavailable. */
uint32_t pf_font_source_scaled(const pf_font_source *src, uint32_t font, float factor);

/* A one-line strip of chrome (a mode line, the tab bar): text with face runs over a base face.
 * The base face gives the background and the foreground and font of characters whose run face
 * sets none. Contents come from Scheme, which formats them. */
typedef struct pf_strip_run {
    uint32_t start, end; /* characters */
    uint32_t face;
} pf_strip_run;

typedef struct pf_strip {
    uint32_t *cps;
    size_t n;
    pf_strip_run *runs;
    size_t nruns;
    uint32_t face; /* 0: no strip */
    uint32_t box;  /* 0 flat, 1 raised (a 1-pixel light top and dark bottom edge), else a border:
                    * 1-pixel top and bottom lines in this RGBA color (its alpha is never 0) */
    uint32_t *dividers; /* character positions with a 1-pixel vertical line at their left edge */
    size_t ndividers;
    uint32_t divider_color; /* RGBA */
} pf_strip;

/* Copies the contents into S; returns 1 if they differ from what S had. FACE 0 empties it. */
int pf_strip_set(pf_strip *s, const uint32_t *cps, size_t n, const pf_strip_run *runs,
                 size_t nruns, uint32_t face, uint32_t box);
void pf_strip_free(pf_strip *s);

/* Sets S's dividers (the tab bar's lines between tabs): N character positions, each drawn as a
 * 1-pixel line the strip's height in COLOR at the left edge of that character (N is the end of
 * the text: its right edge). Returns 1 if they changed. */
int pf_strip_set_dividers(pf_strip *s, const uint32_t *positions, size_t n, uint32_t color);

/* The character of S at X (strip-relative, points), laid out as pf_strip_render lays it out;
 * -1 left of the text, past its end, or for an empty strip. */
long pf_strip_char_at(const pf_strip *s, pf_layout_cache *cache, uint32_t default_font, float x);

/* Height of a strip with base face FACE: one line of its font (DEFAULT_FONT when the face sets
 * none) plus padding, and the box. Points, whole. */
float pf_strip_height(const pf_font_source *src, uint32_t face, uint32_t default_font, uint32_t box);

/* Draws S into the rect X, Y, W, H; text is clipped at the right edge. Call within a layout
 * frame (pf_layout_begin_frame). */
void pf_strip_render(const pf_strip *s, pf_display *d, pf_layout_cache *cache,
                     const pf_font_source *src, uint32_t default_font, float x, float y, float w,
                     float h, float scale);

#endif
