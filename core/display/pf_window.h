#ifndef PF_WINDOW_H
#define PF_WINDOW_H

#include <stddef.h>
#include <stdint.h>

#include "pf_display.h"
#include "pf_handles.h"
#include "pf_layout.h"

/* A window shows one buffer: it scrolls to keep point visible and renders the visible lines
 * into a display list through the layout cache. Lines are truncated at the window edge (no
 * soft wrap yet). Main thread only; portable (fonts arrive as ids and metrics). */

typedef struct pf_window_style {
    uint32_t font;                 /* pf_font_id */
    float ascent, descent, line_height; /* points */
    float cell_width;              /* cursor width at end of line */
    float pad_left, pad_top;
    uint32_t background, foreground, cursor; /* 0xRRGGBBAA */
    uint32_t line_number, line_number_current; /* gutter text */
    uint32_t hl_line;                          /* current-line band */
    uint32_t paren_match, paren_mismatch;      /* bracket highlight backgrounds */
} pf_window_style;

/* Per-window display features (Emacs's display-line-numbers, hl-line, show-paren). */
typedef enum pf_window_option {
    PF_WINDOW_LINE_NUMBERS = 1,
    PF_WINDOW_HL_LINE = 2,
    PF_WINDOW_SHOW_PAREN = 3,
} pf_window_option;

typedef struct pf_window pf_window;

/* CACHE is shared, not owned. */
pf_window *pf_window_new(pf_layout_cache *cache, const pf_window_style *style);
void pf_window_free(pf_window *w);

/* Shows text buffer BUF (a pf_handle) with point at marker POINT of that buffer. */
void pf_window_set_buffer(pf_window *w, pf_handle buf, uint32_t point);
void pf_window_set_size(pf_window *w, float width, float height, float scale);
void pf_window_set_style(pf_window *w, const pf_window_style *style);

/* Renders if anything changed since the last call (text, point, size, style, scroll) and
 * returns the frozen display list (caller releases), else NULL. */
const pf_display *pf_window_redisplay(pf_window *w);

/* Input-method composition (marked text) CPS[0..N), drawn underlined at point without being in
 * the buffer, with the cursor CARET characters into it. N == 0 clears it. */
void pf_window_set_preedit(pf_window *w, const uint32_t *cps, size_t n, size_t caret);

/* The cursor rect drawn by the last redisplay (points, window coordinates, top-left origin);
 * -1 if point was not visible. Used to place input-method candidate windows. */
int pf_window_cursor_rect(const pf_window *w, float rect[4]);

/* Turns OPTION on or off; returns -1 for an unknown option. All start off. */
int pf_window_set_option(pf_window *w, pf_window_option option, int on);
int pf_window_option_value(const pf_window *w, pf_window_option option);

/* Forces the next redisplay to render. */
void pf_window_invalidate(pf_window *w);

size_t pf_window_top_line(const pf_window *w);
/* Lines that fit completely. */
size_t pf_window_body_lines(const pf_window *w);

#endif
