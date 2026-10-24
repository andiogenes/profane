#ifndef PF_BOXDRAW_H
#define PF_BOXDRAW_H

#include <stdint.h>

#include "pf_display.h"

/* Box-drawing (U+2500-257F) and block-element (U+2580-259F) characters drawn as rectangles that
 * fill their cell exactly, so lines and blocks join across cells and rows however the font draws
 * them (a terminal's windows, tables and bars would otherwise show gaps). The cell is X, Y, W, H
 * points. Returns 1 if CP was drawn, 0 if the caller should draw it as an ordinary glyph (other
 * characters, the diagonals U+2571-2573). Colors are 0xRRGGBBAA; shades blend by alpha. */
int pf_boxdraw(pf_display *d, uint32_t cp, float x, float y, float w, float h, uint32_t color);

#endif
