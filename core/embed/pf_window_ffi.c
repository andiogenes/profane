#include "pf_window_ffi.h"

enum { INVALID = -2 };

static pf_handle selected;

pf_handle pf_win_register(pf_window *w) {
    return pf_handle_new(PF_HANDLE_WINDOW, w);
}

void pf_win_unregister(pf_handle win) {
    pf_handle_free(win, PF_HANDLE_WINDOW);
    if (win == selected) {
        selected = 0;
    }
}

void pf_win_set_selected(pf_handle win) {
    selected = win;
}

pf_handle pf_win_selected(void) {
    return pf_handle_get(selected, PF_HANDLE_WINDOW) ? selected : 0;
}

int pf_win_set_buffer(pf_handle win, pf_handle buf, uint32_t point_marker) {
    pf_window *w = pf_handle_get(win, PF_HANDLE_WINDOW);
    if (!w || !pf_handle_get(buf, PF_HANDLE_TEXT)) {
        return INVALID;
    }
    pf_window_set_buffer(w, buf, point_marker);
    return 0;
}

int64_t pf_win_top_line(pf_handle win) {
    pf_window *w = pf_handle_get(win, PF_HANDLE_WINDOW);
    return w ? (int64_t)pf_window_top_line(w) : INVALID;
}

int64_t pf_win_body_lines(pf_handle win) {
    pf_window *w = pf_handle_get(win, PF_HANDLE_WINDOW);
    return w ? (int64_t)pf_window_body_lines(w) : INVALID;
}
