#ifndef PF_WINDOW_FFI_H
#define PF_WINDOW_FFI_H

#include <stddef.h>
#include <stdint.h>

#include "pf_frame.h"
#include "pf_handles.h"

/* Frames and windows for Scheme's `foreign-procedure`, as handles (see pf_buffer_ffi.h for
 * conventions). The platform shell creates the frame; Scheme creates its windows, lays them
 * out and picks what they show. Main thread only. Calls given a bad handle return -2. */

/* Shell side: register F (not owned) and get its handle; mark one as the selected frame. */
pf_handle pf_frm_register(pf_frame *f);
/* Invalidates F's handle and those of its windows; call before freeing F. */
void pf_frm_unregister(pf_handle frame);
void pf_frm_set_selected(pf_handle frame);

/* ---- Scheme side: frames ---- */

pf_handle pf_frm_selected(void); /* 0 if none (e.g. headless) */
/* A frame that is never shown, with its own fixed-width shaper (pf_shaper_fixed) and no fonts:
 * lets Scheme tests run window code without a window server. Freed by pf_frm_free_headless. */
pf_handle pf_frm_new_headless(float width, float height);
int pf_frm_free_headless(pf_handle frame);
double pf_frm_width(pf_handle frame);
double pf_frm_height(pf_handle frame);
/* Line height and cell width of the default font at text scale FACTOR; strip height for a base
 * face (pf_frame_strip_height). */
double pf_frm_line_height(pf_handle frame, float factor);
double pf_frm_cell_width(pf_handle frame, float factor);
double pf_frm_strip_height(pf_handle frame, uint32_t face, int box);
/* UTF8 is the text, RUNS NRUNS triples (start, end, face) in characters. */
int pf_frm_set_tab_bar(pf_handle frame, const char *utf8, size_t len, const uint32_t *runs,
                       size_t nruns, uint32_t face, int box);
/* Renders the frame as the shell would; returns the number of display items, -1 if nothing
 * changed. For tests. */
int64_t pf_frm_redisplay(pf_handle frame);

/* ---- Scheme side: windows ---- */

pf_handle pf_frm_window_new(pf_handle frame); /* 0 on failure */
int pf_frm_window_delete(pf_handle frame, pf_handle win);
int pf_frm_place_window(pf_handle frame, pf_handle win, float x, float y, float width,
                        float height, int shown);
int pf_frm_select_window(pf_handle frame, pf_handle win);
int pf_frm_set_text_scale(pf_handle frame, pf_handle win, float factor);

pf_handle pf_win_selected(void); /* the selected frame's selected window, or 0 */
int pf_win_set_buffer(pf_handle win, pf_handle buf, uint32_t point_marker);
int64_t pf_win_top_line(pf_handle win);
int pf_win_set_top_line(pf_handle win, size_t line);
int64_t pf_win_body_lines(pf_handle win);
/* pf_window_option values; returns -1 for an unknown option. */
int pf_win_set_option(pf_handle win, int option, int value);
int pf_win_option(pf_handle win, int option);
int pf_win_set_edges(pf_handle win, float fringe_left, float fringe_right, float divider);
/* Arguments as for pf_frm_set_tab_bar; FACE 0 removes the mode line. */
int pf_win_set_mode_line(pf_handle win, const char *utf8, size_t len, const uint32_t *runs,
                         size_t nruns, uint32_t face, int box);
double pf_win_mode_line_height(pf_handle win);
double pf_win_hscroll(pf_handle win); /* points */
int pf_win_set_min_hscroll(pf_handle win, float points);

#endif
