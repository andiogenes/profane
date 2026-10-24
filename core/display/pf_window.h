#ifndef PF_WINDOW_H
#define PF_WINDOW_H

#include <stddef.h>
#include <stdint.h>

#include "pf_canvas.h"
#include "pf_display.h"
#include "pf_handles.h"
#include "pf_layout.h"
#include "pf_strip.h"
#include "pf_term.h"

/* A window shows one buffer: it scrolls to keep point visible and renders the visible lines
 * into a display list through the layout cache. Lines are truncated at the window edge unless
 * PF_WINDOW_WRAP is set. Main thread only; portable (fonts arrive as ids and metrics). */

/* Geometry and the default font; colors come from faces (pf_face.h): the default face for text
 * and background, role faces for the cursor, line numbers, hl-line and show-paren, and the
 * PF_PROP_FACE text property for individual characters. */
typedef struct pf_window_style {
    uint32_t font;                 /* pf_font_id, used when the default face sets no font */
    float ascent, descent, line_height; /* points */
    float cell_width;              /* cursor width at end of line */
    float pad_left, pad_top;
} pf_window_style;

/* The text property whose value is a face id (pf_face.h). */
enum { PF_PROP_FACE = 1 };

/* Per-window display features (Emacs's display-line-numbers, hl-line, show-paren) and the
 * cursor: PF_CURSOR_* values (a box by default; hollow in non-selected windows, as in Emacs). */
typedef enum pf_window_option {
    PF_WINDOW_LINE_NUMBERS = 1,
    PF_WINDOW_HL_LINE = 2,
    PF_WINDOW_SHOW_PAREN = 3,
    PF_WINDOW_CURSOR = 4,
    PF_WINDOW_WRAP = 5, /* PF_WRAP_* */
} pf_window_option;

/* Lines longer than the text area: cut at the edge (Emacs's truncate-lines), continued on the next
 * screen row at the last character that fits, or at the last whitespace (word-wrap). */
enum { PF_WRAP_NONE = 0, PF_WRAP_CHAR = 1, PF_WRAP_WORD = 2 };

enum { PF_CURSOR_NONE = 0, PF_CURSOR_BOX = 1, PF_CURSOR_HOLLOW = 2 };

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

/* Sets OPTION (on/off, or a PF_CURSOR_* value); returns -1 for an unknown option. Display
 * features start off, the cursor as a box. */
int pf_window_set_option(pf_window *w, pf_window_option option, int on);
int pf_window_option_value(const pf_window *w, pf_window_option option);

/* Fonts for metrics and text scaling (not owned; NULL: headless fallbacks). */
void pf_window_set_fonts(pf_window *w, const pf_font_source *fonts);

/* Text scale: buffer text is drawn in its faces' fonts at FACTOR times their size. The style
 * (line height, ...) must be that of the scaled default font; the mode line is not scaled. */
void pf_window_set_text_scale(pf_window *w, float factor);

/* Fringes: blank columns at the left and right edges in the fringe face, outside the text
 * area. DIVIDER: a vertical line at the right edge, for a window with a neighbor on its right
 * (Emacs's vertical border). Points. */
void pf_window_set_edges(pf_window *w, float fringe_left, float fringe_right, float divider);

/* The mode line: one line at the bottom of the window (see pf_strip). FACE 0 removes it. */
void pf_window_set_mode_line(pf_window *w, const uint32_t *cps, size_t n,
                             const pf_strip_run *runs, size_t nruns, uint32_t face, int box);
float pf_window_mode_line_height(const pf_window *w);

/* The header line: one line at the top of the window, above the text (see pf_strip). FACE 0
 * removes it. Text, fringes, the cursor and the body rect all start below it. */
void pf_window_set_header_line(pf_window *w, const uint32_t *cps, size_t n,
                               const pf_strip_run *runs, size_t nruns, uint32_t face, int box);
float pf_window_header_line_height(const pf_window *w);

/* Horizontal scroll in points. Redisplay scrolls sideways to keep point visible (Emacs
 * auto-hscroll), never below the minimum set by scroll-left/scroll-right. */
float pf_window_hscroll(const pf_window *w);
void pf_window_set_min_hscroll(pf_window *w, float points);

/* Scrolls so LINE is the first one shown (redisplay still keeps point visible). */
void pf_window_set_top_line(pf_window *w, size_t line);

/* Native-view window kind: a window whose body (everything but the mode line and divider) is
 * left empty for a platform view the shell places there (WKWebView, PDF, ...). KIND 0 is an
 * ordinary text window; others are the shell's view kinds. A native window draws no text,
 * fringes or cursor. */
void pf_window_set_native(pf_window *w, uint32_t kind);
uint32_t pf_window_native(const pf_window *w);
/* The body's rect in window coordinates (points). */
void pf_window_body_rect(const pf_window *w, float rect[4]);

/* Where character POS (of the window's buffer) is on screen: its cell as X, Y, W, H in window
 * coordinates, as the last layout put it. Returns -1 if POS is not in a visible line or is
 * scrolled out sideways. Used for jump labels (avy) and the like. */
int pf_window_pos_rect(pf_window *w, size_t pos, float rect[4]);

/* The character whose cell contains window point (X, Y), as a buffer position: below the last
 * line is the end of the last line, past a line's end is its end. Returns -1 for a point
 * outside the text area vertically (the mode line, or a window without text). The inverse of
 * pf_window_pos_rect, for the mouse. */
int64_t pf_window_pos_at(pf_window *w, float x, float y);

/* The active region [START, END) in characters, drawn in the region face's background under the
 * text; START == END shows none. A newline inside the region shows as one extra cell, as in
 * Emacs. Callers show it in the selected window only. */
void pf_window_set_region(pf_window *w, size_t start, size_t end);

/* Canvas window kind: the body (see pf_window_body_rect) shows CANVAS, drawn on the base layer
 * from (0, 0) at the body's top-left, instead of text; NULL makes it a text window again. Not
 * owned: detach it before freeing the canvas. Ops outside the body are not clipped yet, so
 * size the canvas to the body. A canvas window draws no fringes or cursor. */
void pf_window_set_canvas(pf_window *w, pf_canvas *canvas);
pf_canvas *pf_window_canvas(const pf_window *w);

/* Terminal window kind: the body shows TERM's cell grid (colors, attributes, cursor) instead of
 * text, from the body's top-left, one cell per column and row of the window's style. FACES are
 * the face ids for regular, bold, italic and bold-italic text (their fonts; a face with none
 * uses the default font); the cursor takes the cursor role's background. NULL TERM makes it a
 * text window again. Not owned: detach it before freeing the terminal. A terminal window draws
 * no fringes; the terminal is redrawn when its version moves. */
void pf_window_set_terminal(pf_window *w, pf_term *term, const uint32_t faces[4]);
pf_term *pf_window_terminal(const pf_window *w);
/* How many rows and columns of terminal cells fit the body now. */
void pf_window_terminal_size(const pf_window *w, int *rows, int *cols);

/* Screen rows (soft wrap). The row of POS as the window would lay it out now, visible or not:
 * its characters are [*START, *END) (END is the line's end on its last row, else the first
 * character of the next row). Returns -1 if the window shows no text. */
int pf_window_row_bounds(pf_window *w, size_t pos, size_t *start, size_t *end);
/* X of POS in its row, in points from the row's first character. */
float pf_window_row_x(pf_window *w, size_t pos);
/* The position DELTA screen rows from POS (negative: up) whose x in its row is nearest GOAL_X
 * (past the row's end: the end), stopping at the first and last rows of the buffer. */
size_t pf_window_move_rows(pf_window *w, size_t pos, long delta, float goal_x);

/* Marks in the left fringe, e.g. changes since the index: N triples of (LINE, COUNT, KIND) in
 * TRIPLES, sorted by line, KIND 1 added, 2 modified, 3 deleted (a tick at the top of LINE,
 * after the last line at its bottom). N == 0 clears them. Bars take the git roles' colors. */
void pf_window_set_line_marks(pf_window *w, const uint32_t *triples, size_t n);

/* Forces the next redisplay to render. */
void pf_window_invalidate(pf_window *w);

size_t pf_window_top_line(const pf_window *w);
/* Lines that fit completely above the mode line. */
size_t pf_window_body_lines(const pf_window *w);

#endif
