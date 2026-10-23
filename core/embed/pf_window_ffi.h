#ifndef PF_WINDOW_FFI_H
#define PF_WINDOW_FFI_H

#include <stdint.h>

#include "pf_handles.h"
#include "pf_window.h"

/* Windows for Scheme's `foreign-procedure`, as handles (see pf_buffer_ffi.h for conventions).
 * The platform shell creates windows; Scheme picks what they show. Main thread only. */

/* Shell side: register W (not owned) and get its handle; mark one as selected. */
pf_handle pf_win_register(pf_window *w);
void pf_win_unregister(pf_handle win);
void pf_win_set_selected(pf_handle win);

/* Scheme side. */
pf_handle pf_win_selected(void); /* 0 if no window (e.g. headless) */
int pf_win_set_buffer(pf_handle win, pf_handle buf, uint32_t point_marker);
int64_t pf_win_top_line(pf_handle win);
int64_t pf_win_body_lines(pf_handle win);

#endif
