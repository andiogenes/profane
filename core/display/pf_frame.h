#ifndef PF_FRAME_H
#define PF_FRAME_H

#include <stddef.h>
#include <stdint.h>

#include "pf_display.h"
#include "pf_layout.h"
#include "pf_strip.h"
#include "pf_window.h"

/* A frame: the windows of one editor surface, composed into one display list for the base
 * layer. Scheme owns the window tree and lays it out; the frame places each window where it is
 * told, renders only windows that changed, moves their lists into place and draws the tab bar
 * across the top. Window styles (line height, ...) follow the default face and each window's
 * text scale. Main thread only; portable. */

typedef struct pf_frame pf_frame;

/* CACHE and FONTS are not owned (FONTS may be NULL: headless). BASE_FONT is the code font used
 * while the default face sets none. */
pf_frame *pf_frame_new(pf_layout_cache *cache, const pf_font_source *fonts, uint32_t base_font);
/* Frees the frame and its windows. */
void pf_frame_free(pf_frame *f);

void pf_frame_set_size(pf_frame *f, float width, float height, float scale);
float pf_frame_width(const pf_frame *f);
float pf_frame_height(const pf_frame *f);

/* A new window, not shown until placed. TAG is the caller's (e.g. its handle). */
pf_window *pf_frame_add_window(pf_frame *f, uint32_t tag);
/* Removes and frees W; returns -1 if W is not in F. */
int pf_frame_remove_window(pf_frame *f, pf_window *w);
size_t pf_frame_window_count(const pf_frame *f);
uint32_t pf_frame_window_tag(const pf_frame *f, size_t i);
void pf_frame_set_window_tag(pf_frame *f, pf_window *w, uint32_t tag);

/* Shows W in the rect X, Y, WIDTH, HEIGHT (points, top-left origin), or hides it (SHOWN 0, a
 * window of another tab). Returns -1 if W is not in F. */
int pf_frame_place_window(pf_frame *f, pf_window *w, float x, float y, float width, float height,
                          int shown);
/* W's text scale (pf_window_set_text_scale), with its style to match. */
int pf_frame_set_text_scale(pf_frame *f, pf_window *w, float factor);

/* The selected window: input-method composition and its candidate window go there. */
void pf_frame_select(pf_frame *f, pf_window *w);
pf_window *pf_frame_selected(const pf_frame *f);

/* The tab bar across the top (pf_strip); FACE 0 hides it. Its height is pf_frame_strip_height. */
void pf_frame_set_tab_bar(pf_frame *f, const uint32_t *cps, size_t n, const pf_strip_run *runs,
                          size_t nruns, uint32_t face, int box);

/* Metrics Scheme lays windows out with: the window style at text scale FACTOR, and the height
 * of a strip (mode line, tab bar) with base face FACE. */
pf_window_style pf_frame_text_style(const pf_frame *f, float factor);
float pf_frame_strip_height(const pf_frame *f, uint32_t face, int box);

/* Renders what changed and returns the composed list (caller releases), or NULL if nothing
 * did. */
const pf_display *pf_frame_redisplay(pf_frame *f);

/* The selected window's cursor rect in frame coordinates (pf_window_cursor_rect). */
int pf_frame_cursor_rect(const pf_frame *f, float rect[4]);

#endif
