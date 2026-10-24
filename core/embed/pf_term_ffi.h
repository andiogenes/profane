#ifndef PF_TERM_FFI_H
#define PF_TERM_FFI_H

#include <stddef.h>
#include <stdint.h>

#include "pf_handles.h"

/* Terminals (core/term/pf_term.h) for Scheme's `foreign-procedure`, as handles (see
 * pf_buffer_ffi.h for conventions). Strings are UTF-8 with a length. Main thread only. Calls
 * given a bad handle return -2. */

pf_handle pf_trm_new(int rows, int cols, int scrollback); /* 0 on failure */
/* Detaches the terminal from the windows showing it (in the selected frame) and frees it. */
int pf_trm_free(pf_handle term);

int pf_trm_resize(pf_handle term, int rows, int cols);
int pf_trm_rows(pf_handle term);
int pf_trm_cols(pf_handle term);
int64_t pf_trm_version(pf_handle term);

int pf_trm_feed(pf_handle term, const char *bytes, size_t len);
/* Up to CAP bytes the terminal wants sent to the program. */
int64_t pf_trm_output(pf_handle term, char *buf, size_t cap);
/* FG and BG as 0xRRGGBB; ANSI: 16 native-endian uint32 colors (64 bytes). */
int pf_trm_set_colors(pf_handle term, uint32_t fg, uint32_t bg, const uint32_t *ansi);

int pf_trm_key(pf_handle term, const char *key, size_t len);
int pf_trm_text(pf_handle term, const char *utf8, size_t len);
int pf_trm_paste(pf_handle term, const char *utf8, size_t len);

int pf_trm_scroll_view(pf_handle term, int lines);
int pf_trm_view_offset(pf_handle term);
int pf_trm_scrollback(pf_handle term);
/* FIELD: 0 row, 1 column, 2 visible, 3 shape, 4 blink. */
int pf_trm_cursor(pf_handle term, int field);
int64_t pf_trm_title(pf_handle term, char *buf, size_t cap);
int64_t pf_trm_bells(pf_handle term);
int pf_trm_alt_screen(pf_handle term);
int pf_trm_mouse_mode(pf_handle term);
int64_t pf_trm_dump(pf_handle term, char *buf, size_t cap);

/* Shows TERM (0: none) in window WIN of FRAME, in the faces FACE0-3 (regular, bold, italic,
 * bold-italic). */
int pf_trm_set_window(pf_handle frame, pf_handle win, pf_handle term, uint32_t face0,
                      uint32_t face1, uint32_t face2, uint32_t face3);
/* FIELD 0: rows, 1: columns that fit window WIN's body. */
int pf_trm_window_size(pf_handle win, int field);

#endif
