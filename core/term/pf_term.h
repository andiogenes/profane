#ifndef PF_TERM_H
#define PF_TERM_H

#include <stddef.h>
#include <stdint.h>

/* A terminal emulator state: libvterm's screen plus a scrollback of lines that scrolled off it,
 * seen through a viewport. Bytes from a program go in with pf_term_feed; what the terminal says
 * back (key presses, answers to queries) comes out of pf_term_output to be written to the
 * program. Rendering reads cells. Main thread only; portable (no Chez, no platform). */

typedef struct pf_term pf_term;

/* ROWS x COLS cells, keeping up to SCROLLBACK lines that scrolled off the top. */
pf_term *pf_term_new(int rows, int cols, int scrollback);
void pf_term_free(pf_term *t);

int pf_term_rows(const pf_term *t);
int pf_term_cols(const pf_term *t);
void pf_term_resize(pf_term *t, int rows, int cols);

/* Bumped by every change that can alter what is drawn (output, resize, colors, scrolling the view,
 * the cursor). A renderer redraws when it moved. */
uint64_t pf_term_version(const pf_term *t);

/* Program output. */
void pf_term_feed(pf_term *t, const void *bytes, size_t len);
/* Moves up to CAP bytes the terminal wants sent to the program into BUF; returns how many. */
size_t pf_term_output(pf_term *t, void *buf, size_t cap);

/* Default text colors and the 16 ANSI colors (index 0-15), 0xRRGGBB. Other indexed colors
 * (16-255) follow the xterm palette. */
void pf_term_set_colors(pf_term *t, uint32_t fg, uint32_t bg, const uint32_t ansi[16]);

/* ---- input ---- */

/* A key as profane names it: "a", "C-a", "M-x", "RET", "TAB", "DEL" (backspace), "ESC", "SPC",
 * "<up>", "<f5>", "S-<left>", ... Writes what the program expects to the output. Returns 0, or -1
 * for a key the terminal has no encoding for. */
int pf_term_key(pf_term *t, const char *key, size_t len);
/* Typed text (UTF-8). */
void pf_term_text(pf_term *t, const char *utf8, size_t len);
/* Pasted text, in bracketed-paste markers when the program asked for them. */
void pf_term_paste(pf_term *t, const char *utf8, size_t len);

/* ---- looking ---- */

enum { PF_TERM_MAX_CPS = 6 };

typedef struct pf_term_cell {
    uint32_t cps[PF_TERM_MAX_CPS]; /* code points, 0-terminated unless full; cps[0] == 0: blank */
    uint32_t fg, bg;               /* 0xRRGGBBAA after reverse video */
    uint8_t width;                 /* 1, or 2 for a wide character (the next cell is its right half) */
    uint8_t bg_default;            /* the background is the default one (nothing to paint) */
    uint8_t bold, italic, underline, strike, blink, conceal;
} pf_term_cell;

/* Cell (ROW, COL) of the viewport: row 0 is its top. At offset 0 the viewport is the live screen;
 * a positive offset shows that many lines of scrollback above. A cell right of a wide character
 * has width 0. Out-of-range cells are blank. */
void pf_term_cell_get(const pf_term *t, int row, int col, pf_term_cell *out);

/* Scrolls the viewport by LINES (positive: back into history), clamped. Any output returns it
 * to the live screen. Returns the new offset. */
int pf_term_scroll_view(pf_term *t, int lines);
int pf_term_view_offset(const pf_term *t);
int pf_term_scrollback_lines(const pf_term *t);

/* The cursor in the live screen; hidden while the viewport is scrolled back (VISIBLE 0). SHAPE:
 * 1 block, 2 underline, 3 bar. */
void pf_term_cursor(const pf_term *t, int *row, int *col, int *visible, int *shape, int *blink);

/* The window title the program set; returns its length. */
size_t pf_term_title(const pf_term *t, char *buf, size_t cap);
/* How many times the program rang the bell. */
uint64_t pf_term_bell_count(const pf_term *t);
/* Whether the alternate screen is in use (full-screen programs: no scrollback is kept there). */
int pf_term_alt_screen(const pf_term *t);
/* The mouse reporting the program asked for: 0 none, 1 click, 2 drag, 3 move. */
int pf_term_mouse_mode(const pf_term *t);

/* The scrollback and the screen as UTF-8 text, one line per row, trailing blanks trimmed, written
 * into BUF (up to CAP bytes). Returns the full length. */
size_t pf_term_text_dump(const pf_term *t, char *buf, size_t cap);

#endif
