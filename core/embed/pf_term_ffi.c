#include "pf_term_ffi.h"

#include <stdlib.h>

#include "pf_frame.h"
#include "pf_term.h"
#include "pf_window_ffi.h"

enum { INVALID = -2 };

static pf_term *term_of(pf_handle h) {
    return pf_handle_get(h, PF_HANDLE_TERM);
}

pf_handle pf_trm_new(int rows, int cols, int scrollback) {
    pf_term *t = pf_term_new(rows, cols, scrollback);
    pf_handle h = pf_handle_new(PF_HANDLE_TERM, t);
    if (!h) {
        pf_term_free(t);
    }
    return h;
}

int pf_trm_free(pf_handle h) {
    pf_term *t = pf_handle_free(h, PF_HANDLE_TERM);
    if (!t) {
        return INVALID;
    }
    pf_frame *f = pf_handle_get(pf_frm_selected(), PF_HANDLE_FRAME);
    if (f) {
        pf_frame_detach_terminal(f, t);
    }
    pf_term_free(t);
    return 0;
}

#define WITH_TERM(t)                                                                               \
    pf_term *t = term_of(h);                                                                       \
    if (!t) {                                                                                      \
        return INVALID;                                                                            \
    }

int pf_trm_resize(pf_handle h, int rows, int cols) {
    WITH_TERM(t)
    pf_term_resize(t, rows, cols);
    return 0;
}

int pf_trm_rows(pf_handle h) {
    WITH_TERM(t)
    return pf_term_rows(t);
}

int pf_trm_cols(pf_handle h) {
    WITH_TERM(t)
    return pf_term_cols(t);
}

int64_t pf_trm_version(pf_handle h) {
    WITH_TERM(t)
    return (int64_t)pf_term_version(t);
}

int pf_trm_feed(pf_handle h, const char *bytes, size_t len) {
    WITH_TERM(t)
    pf_term_feed(t, bytes, len);
    return 0;
}

int64_t pf_trm_output(pf_handle h, char *buf, size_t cap) {
    WITH_TERM(t)
    return (int64_t)pf_term_output(t, buf, cap);
}

int pf_trm_set_colors(pf_handle h, uint32_t fg, uint32_t bg, const uint32_t *ansi) {
    WITH_TERM(t)
    pf_term_set_colors(t, fg, bg, ansi);
    return 0;
}

int pf_trm_key(pf_handle h, const char *key, size_t len) {
    WITH_TERM(t)
    return pf_term_key(t, key, len);
}

int pf_trm_text(pf_handle h, const char *utf8, size_t len) {
    WITH_TERM(t)
    pf_term_text(t, utf8, len);
    return 0;
}

int pf_trm_paste(pf_handle h, const char *utf8, size_t len) {
    WITH_TERM(t)
    pf_term_paste(t, utf8, len);
    return 0;
}

int pf_trm_scroll_view(pf_handle h, int lines) {
    WITH_TERM(t)
    return pf_term_scroll_view(t, lines);
}

int pf_trm_view_offset(pf_handle h) {
    WITH_TERM(t)
    return pf_term_view_offset(t);
}

int pf_trm_scrollback(pf_handle h) {
    WITH_TERM(t)
    return pf_term_scrollback_lines(t);
}

int pf_trm_cursor(pf_handle h, int field) {
    WITH_TERM(t)
    int v[5];
    pf_term_cursor(t, &v[0], &v[1], &v[2], &v[3], &v[4]);
    return field >= 0 && field < 5 ? v[field] : INVALID;
}

int64_t pf_trm_title(pf_handle h, char *buf, size_t cap) {
    WITH_TERM(t)
    return (int64_t)pf_term_title(t, buf, cap);
}

int64_t pf_trm_bells(pf_handle h) {
    WITH_TERM(t)
    return (int64_t)pf_term_bell_count(t);
}

int pf_trm_alt_screen(pf_handle h) {
    WITH_TERM(t)
    return pf_term_alt_screen(t);
}

int pf_trm_mouse_mode(pf_handle h) {
    WITH_TERM(t)
    return pf_term_mouse_mode(t);
}

int64_t pf_trm_dump(pf_handle h, char *buf, size_t cap) {
    WITH_TERM(t)
    return (int64_t)pf_term_text_dump(t, buf, cap);
}

int pf_trm_set_window(pf_handle frame, pf_handle win, pf_handle term, uint32_t face0,
                      uint32_t face1, uint32_t face2, uint32_t face3) {
    pf_frame *f = pf_handle_get(frame, PF_HANDLE_FRAME);
    pf_window *w = pf_handle_get(win, PF_HANDLE_WINDOW);
    pf_term *t = term ? term_of(term) : NULL;
    if (!f || !w || (term && !t)) {
        return INVALID;
    }
    uint32_t faces[4] = {face0, face1, face2, face3};
    return pf_frame_set_window_terminal(f, w, t, faces);
}

int pf_trm_window_size(pf_handle win, int field) {
    pf_window *w = pf_handle_get(win, PF_HANDLE_WINDOW);
    int v[2];
    if (!w || field < 0 || field > 1) {
        return INVALID;
    }
    pf_window_terminal_size(w, &v[0], &v[1]);
    return v[field];
}
