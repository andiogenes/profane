#include "pf_window_ffi.h"

#include <stdlib.h>

#include "pf_utf8.h"

enum { INVALID = -2 };

static pf_handle selected;

/* Headless frames own their layout cache; remembered here to free it with the frame. */
typedef struct headless {
    pf_handle frame;
    pf_layout_cache *cache;
} headless;

static headless *headless_frames;
static size_t nheadless;

static pf_frame *frame_of(pf_handle h) {
    return pf_handle_get(h, PF_HANDLE_FRAME);
}

static pf_window *window_of(pf_handle h) {
    return pf_handle_get(h, PF_HANDLE_WINDOW);
}

pf_handle pf_frm_register(pf_frame *f) {
    return pf_handle_new(PF_HANDLE_FRAME, f);
}

void pf_frm_unregister(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    if (!f) {
        return;
    }
    for (size_t i = 0; i < pf_frame_window_count(f); i++) {
        pf_handle_free(pf_frame_window_tag(f, i), PF_HANDLE_WINDOW);
    }
    pf_handle_free(frame, PF_HANDLE_FRAME);
    if (frame == selected) {
        selected = 0;
    }
}

void pf_frm_set_selected(pf_handle frame) {
    selected = frame;
}

pf_handle pf_frm_selected(void) {
    return frame_of(selected) ? selected : 0;
}

pf_handle pf_frm_new_headless(float width, float height) {
    headless *grown = realloc(headless_frames, (nheadless + 1) * sizeof *grown);
    if (!grown) {
        return 0;
    }
    headless_frames = grown;
    pf_layout_cache *cache = pf_layout_cache_new(pf_shaper_fixed(), 1024, 8);
    pf_frame *f = cache ? pf_frame_new(cache, NULL, 1) : NULL;
    pf_handle h = f ? pf_frm_register(f) : 0;
    if (!h) {
        pf_frame_free(f);
        pf_layout_cache_free(cache);
        return 0;
    }
    pf_frame_set_size(f, width, height, 2);
    headless_frames[nheadless++] = (headless){h, cache};
    return h;
}

int pf_frm_free_headless(pf_handle frame) {
    for (size_t i = 0; i < nheadless; i++) {
        if (headless_frames[i].frame == frame) {
            pf_frame *f = frame_of(frame);
            pf_frm_unregister(frame);
            pf_frame_free(f);
            pf_layout_cache_free(headless_frames[i].cache);
            headless_frames[i] = headless_frames[--nheadless];
            return 0;
        }
    }
    return INVALID;
}

double pf_frm_width(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    return f ? pf_frame_width(f) : INVALID;
}

double pf_frm_height(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    return f ? pf_frame_height(f) : INVALID;
}

double pf_frm_line_height(pf_handle frame, float factor) {
    pf_frame *f = frame_of(frame);
    return f ? pf_frame_text_style(f, factor).line_height : INVALID;
}

double pf_frm_cell_width(pf_handle frame, float factor) {
    pf_frame *f = frame_of(frame);
    return f ? pf_frame_text_style(f, factor).cell_width : INVALID;
}

double pf_frm_strip_height(pf_handle frame, uint32_t face, int box) {
    pf_frame *f = frame_of(frame);
    return f ? pf_frame_strip_height(f, face, box) : INVALID;
}

/* Decodes UTF8 into a fresh array of code points (raw bytes as U+FFFD); *N gets the count. */
static uint32_t *decode(const char *utf8, size_t len, size_t *n) {
    const unsigned char *p = (const unsigned char *)utf8;
    uint32_t *cps = malloc((len ? len : 1) * sizeof *cps);
    size_t k = 0;
    for (size_t i = 0; cps && i < len;) {
        size_t u = pf_utf8_unit_len(p + i, len - i);
        uint32_t cp;
        if (u == 1) {
            cp = p[i] < 0x80 ? p[i] : 0xFFFD;
        } else {
            cp = p[i] & (0x7F >> u);
            for (size_t j = 1; j < u; j++) {
                cp = cp << 6 | (p[i + j] & 0x3F);
            }
        }
        cps[k++] = cp;
        i += u;
    }
    *n = k;
    return cps;
}

typedef void (*strip_setter)(void *target, const uint32_t *cps, size_t n,
                             const pf_strip_run *runs, size_t nruns, uint32_t face, int box);

static int set_strip(void *target, strip_setter set, const char *utf8, size_t len,
                     const uint32_t *runs, size_t nruns, uint32_t face, int box) {
    size_t n;
    uint32_t *cps = decode(utf8, len, &n);
    pf_strip_run *r = malloc((nruns ? nruns : 1) * sizeof *r);
    if (!cps || !r) {
        free(cps);
        free(r);
        return -1;
    }
    for (size_t i = 0; i < nruns; i++) {
        r[i] = (pf_strip_run){runs[3 * i], runs[3 * i + 1], runs[3 * i + 2]};
    }
    set(target, cps, n, r, nruns, face, box);
    free(cps);
    free(r);
    return 0;
}

static void set_tab_bar(void *f, const uint32_t *cps, size_t n, const pf_strip_run *runs,
                        size_t nruns, uint32_t face, int box) {
    pf_frame_set_tab_bar(f, cps, n, runs, nruns, face, box);
}

static void set_mode_line(void *w, const uint32_t *cps, size_t n, const pf_strip_run *runs,
                          size_t nruns, uint32_t face, int box) {
    pf_window_set_mode_line(w, cps, n, runs, nruns, face, box);
}

int pf_frm_set_tab_bar(pf_handle frame, const char *utf8, size_t len, const uint32_t *runs,
                       size_t nruns, uint32_t face, int box) {
    pf_frame *f = frame_of(frame);
    return f ? set_strip(f, set_tab_bar, utf8, len, runs, nruns, face, box) : INVALID;
}

int64_t pf_frm_redisplay(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    if (!f) {
        return INVALID;
    }
    const pf_display *d = pf_frame_redisplay(f);
    if (!d) {
        return -1;
    }
    int64_t n = (int64_t)pf_display_count(d);
    pf_display_release(d);
    return n;
}

int pf_frm_set_window_native(pf_handle frame, pf_handle win, uint32_t kind) {
    pf_frame *f = frame_of(frame);
    pf_window *w = window_of(win);
    return f && w ? pf_frame_set_window_native(f, w, kind) : INVALID;
}

int64_t pf_frm_native_count(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    return f ? (int64_t)pf_frame_native_count(f) : INVALID;
}

double pf_frm_native_field(pf_handle frame, size_t i, int field) {
    pf_frame *f = frame_of(frame);
    pf_native_placement p;
    if (!f || pf_frame_native_get(f, i, &p) != 0) {
        return -1e9;
    }
    switch (field) {
    case 0: return p.x;
    case 1: return p.y;
    case 2: return p.w;
    case 3: return p.h;
    case 4: return p.shown;
    case 5: return p.kind;
    case 6: return p.tag;
    default: return -1e9;
    }
}

pf_handle pf_frm_window_new(pf_handle frame) {
    pf_frame *f = frame_of(frame);
    if (!f) {
        return 0;
    }
    pf_window *w = pf_frame_add_window(f, 0);
    pf_handle h = pf_handle_new(PF_HANDLE_WINDOW, w);
    if (!h) {
        pf_frame_remove_window(f, w);
        return 0;
    }
    pf_frame_set_window_tag(f, w, h);
    return h;
}

int pf_frm_window_delete(pf_handle frame, pf_handle win) {
    pf_frame *f = frame_of(frame);
    pf_window *w = window_of(win);
    if (!f || !w || pf_frame_remove_window(f, w) != 0) {
        return INVALID;
    }
    pf_handle_free(win, PF_HANDLE_WINDOW);
    return 0;
}

int pf_frm_place_window(pf_handle frame, pf_handle win, float x, float y, float width,
                        float height, int shown) {
    pf_frame *f = frame_of(frame);
    pf_window *w = window_of(win);
    return f && w ? pf_frame_place_window(f, w, x, y, width, height, shown) : INVALID;
}

int pf_frm_select_window(pf_handle frame, pf_handle win) {
    pf_frame *f = frame_of(frame);
    pf_window *w = window_of(win);
    if (!f || !w) {
        return INVALID;
    }
    pf_frame_select(f, w);
    return 0;
}

int pf_frm_set_text_scale(pf_handle frame, pf_handle win, float factor) {
    pf_frame *f = frame_of(frame);
    pf_window *w = window_of(win);
    return f && w ? pf_frame_set_text_scale(f, w, factor) : INVALID;
}

pf_handle pf_win_selected(void) {
    pf_frame *f = frame_of(selected);
    pf_window *w = f ? pf_frame_selected(f) : NULL;
    if (!w) {
        return 0;
    }
    for (size_t i = 0; i < pf_frame_window_count(f); i++) {
        pf_handle h = pf_frame_window_tag(f, i);
        if (window_of(h) == w) {
            return h;
        }
    }
    return 0;
}

int pf_win_set_buffer(pf_handle win, pf_handle buf, uint32_t point_marker) {
    pf_window *w = window_of(win);
    if (!w || !pf_handle_get(buf, PF_HANDLE_TEXT)) {
        return INVALID;
    }
    pf_window_set_buffer(w, buf, point_marker);
    return 0;
}

int64_t pf_win_top_line(pf_handle win) {
    pf_window *w = window_of(win);
    return w ? (int64_t)pf_window_top_line(w) : INVALID;
}

int pf_win_set_top_line(pf_handle win, size_t line) {
    pf_window *w = window_of(win);
    if (!w) {
        return INVALID;
    }
    pf_window_set_top_line(w, line);
    return 0;
}

int64_t pf_win_body_lines(pf_handle win) {
    pf_window *w = window_of(win);
    return w ? (int64_t)pf_window_body_lines(w) : INVALID;
}

int pf_win_set_option(pf_handle win, int option, int value) {
    pf_window *w = window_of(win);
    return w ? pf_window_set_option(w, (pf_window_option)option, value) : INVALID;
}

int pf_win_option(pf_handle win, int option) {
    pf_window *w = window_of(win);
    return w ? pf_window_option_value(w, (pf_window_option)option) : INVALID;
}

int pf_win_set_region(pf_handle win, size_t start, size_t end) {
    pf_window *w = window_of(win);
    if (!w) {
        return INVALID;
    }
    pf_window_set_region(w, start, end);
    return 0;
}

int pf_win_set_edges(pf_handle win, float fringe_left, float fringe_right, float divider) {
    pf_window *w = window_of(win);
    if (!w) {
        return INVALID;
    }
    pf_window_set_edges(w, fringe_left, fringe_right, divider);
    return 0;
}

int pf_win_set_mode_line(pf_handle win, const char *utf8, size_t len, const uint32_t *runs,
                         size_t nruns, uint32_t face, int box) {
    pf_window *w = window_of(win);
    return w ? set_strip(w, set_mode_line, utf8, len, runs, nruns, face, box) : INVALID;
}

double pf_win_hscroll(pf_handle win) {
    pf_window *w = window_of(win);
    return w ? pf_window_hscroll(w) : INVALID;
}

int pf_win_set_min_hscroll(pf_handle win, float points) {
    pf_window *w = window_of(win);
    if (!w) {
        return INVALID;
    }
    pf_window_set_min_hscroll(w, points);
    return 0;
}

double pf_win_mode_line_height(pf_handle win) {
    pf_window *w = window_of(win);
    return w ? pf_window_mode_line_height(w) : INVALID;
}
