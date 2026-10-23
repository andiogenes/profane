#ifndef PF_DISPLAY_H
#define PF_DISPLAY_H

#include <stddef.h>
#include <stdint.h>

/* Display list: what one layer should show, as an ordered list of solid rects and positioned
 * glyphs. Built on the main thread, then frozen and handed to the render thread, which only
 * reads it (it never touches Scheme or editor state). Coordinates are points, origin top-left;
 * the renderer scales to pixels. Colors are sRGB 0xRRGGBBAA, not premultiplied. */

typedef struct pf_display pf_display;

typedef enum pf_display_kind {
    PF_DISPLAY_RECT,
    PF_DISPLAY_GLYPH,
} pf_display_kind;

typedef struct pf_display_item {
    uint32_t kind;
    uint32_t color;
    float x, y; /* rect: top-left corner; glyph: pen position on the baseline */
    union {
        struct {
            float w, h;
        } rect;
        struct {
            uint32_t font; /* pf_font_id */
            uint32_t glyph;
        } glyph;
    } u;
} pf_display_item;

/* Starts a list for a WIDTH x HEIGHT point surface at SCALE pixels per point, cleared to CLEAR
 * (alpha 0 for a transparent layer). Aborts on allocation failure, like the text core. */
pf_display *pf_display_new(float width, float height, float scale, uint32_t clear);

void pf_display_rect(pf_display *d, float x, float y, float w, float h, uint32_t color);
void pf_display_glyph(pf_display *d, uint32_t font, uint32_t glyph, float x, float baseline,
                      uint32_t color);

/* Freezes the list; no further items may be added. Returns it with one reference. */
const pf_display *pf_display_finish(pf_display *d);

const pf_display *pf_display_retain(const pf_display *d);
void pf_display_release(const pf_display *d);

float pf_display_width(const pf_display *d);
float pf_display_height(const pf_display *d);
float pf_display_scale(const pf_display *d);
uint32_t pf_display_clear(const pf_display *d);
size_t pf_display_count(const pf_display *d);
const pf_display_item *pf_display_items(const pf_display *d);

#endif
