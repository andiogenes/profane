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
double pf_frm_strip_height(pf_handle frame, uint32_t face, uint32_t box);
/* UTF8 is the text, RUNS NRUNS triples (start, end, face) in characters. */
int pf_frm_set_tab_bar(pf_handle frame, const char *utf8, size_t len, const uint32_t *runs,
                       size_t nruns, uint32_t face, uint32_t box);
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

/* Native-view windows (see pf_frame.h): KIND 0 makes WIN a text window again. */
int pf_frm_set_window_native(pf_handle frame, pf_handle win, uint32_t kind);
int64_t pf_frm_native_count(pf_handle frame);
/* Field FIELD of the I-th native window's placement: 0-3 the body rect x, y, w, h, 4 shown,
 * 5 kind, 6 the window's handle. Returns -1e9 if out of range. */
double pf_frm_native_field(pf_handle frame, size_t i, int field);

/* The active region [START, END) of WIN, in characters; START == END clears it. */
int pf_win_set_region(pf_handle win, size_t start, size_t end);

/* Where character POS is in WIN (pf_window_pos_rect): OUT receives four floats (x, y, w, h) in window
 * coordinates. Returns 0, or -1 if it is not visible. */
int pf_win_pos_rect(pf_handle win, size_t pos, uint8_t *out);

/* The buffer position under window point (X, Y) (pf_window_pos_at), or -1. */
int64_t pf_win_pos_at(pf_handle win, float x, float y);
/* Screen rows (pf_window_row_bounds, pf_window_row_x, pf_window_move_rows): the first and one past
 * the last character of POS's row, its x within the row, and the position DELTA rows away at GOAL_X. */
int64_t pf_win_row_start(pf_handle win, size_t pos);
int64_t pf_win_row_end(pf_handle win, size_t pos);
double pf_win_row_x(pf_handle win, size_t pos);
int64_t pf_win_move_rows(pf_handle win, size_t pos, int64_t delta, float goal_x);
/* The fringe marks of WIN (pf_window_set_line_marks): N triples of uint32 in the bytes TRIPLES. */
int pf_win_set_line_marks(pf_handle win, const uint32_t *triples, size_t n);
/* The motion level (pf_motion_set_level): 0 off, 1 subtle, 2 full. */
int pf_motion_set_level_ffi(int level);
int pf_motion_set_feature_ffi(int feature, int on); /* pf_motion_set_feature */
int pf_motion_set_scroll_ffi(int on); /* smooth scrolling (pf_motion_set_scroll) */
int pf_motion_set_cursor_ffi(int on); /* the animated cursor (pf_motion_set_cursor) */
/* The mouse cursor over frame point (X, Y) (pf_frame_cursor_at): 0 arrow, 1 pointer, 2 text. */
int pf_frm_cursor_at(pf_handle frame, float x, float y);

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
                         size_t nruns, uint32_t face, uint32_t box);
double pf_win_mode_line_height(pf_handle win);
/* The header line at the top of WIN (args as for pf_win_set_mode_line); FACE 0 removes it. */
int pf_win_set_header_line(pf_handle win, const char *utf8, size_t len, const uint32_t *runs,
                           size_t nruns, uint32_t face, uint32_t box);
double pf_win_header_line_height(pf_handle win);
double pf_win_hscroll(pf_handle win); /* points */
int pf_win_set_min_hscroll(pf_handle win, float points);

#endif
