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
    PF_DISPLAY_ROUND_RECT, /* filled, or a RADIUS-rounded outline LINE points wide */
    PF_DISPLAY_SHADOW,     /* a rounded box blurred by BLUR (a gaussian's sigma), for drop shadows */
    PF_DISPLAY_CLIP,       /* later items draw only inside the rect (rect.w, rect.h) */
    PF_DISPLAY_UNCLIP,     /* ends the clip */
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
            float w, h;
            float radius;
            float extra; /* round rect: outline width (0: filled); shadow: blur sigma */
        } round;
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
/* A rounded rectangle, filled (LINE 0) or as an outline LINE points wide drawn inside it. */
void pf_display_round_rect(pf_display *d, float x, float y, float w, float h, float radius,
                           float line, uint32_t color);
/* The shadow of a rounded box X, Y, W, H: COLOR (its alpha is the darkest point) fading out over
 * BLUR points either side of the box edge (BLUR is the blur's reach, not a pixel kernel). The
 * box itself is shadowed too: draw it on top. */
void pf_display_shadow(pf_display *d, float x, float y, float w, float h, float radius, float blur,
                       uint32_t color);
/* Clips the items that follow to the rect X, Y, W, H until pf_display_unclip. Clips do not nest:
 * a new one replaces the current. A clip is not carried across pf_display_append, so every list
 * that clips must end it. */
void pf_display_clip(pf_display *d, float x, float y, float w, float h);
void pf_display_unclip(pf_display *d);
void pf_display_glyph(pf_display *d, uint32_t font, uint32_t glyph, float x, float baseline,
                      uint32_t color);

/* Appends the items of frozen list SRC, moved by (DX, DY); its clear color is not drawn. Used to
 * compose windows rendered on their own into one frame. */
void pf_display_append(pf_display *d, const pf_display *src, float dx, float dy);

/* Like pf_display_append, with every color's alpha multiplied by ALPHA (0..1): fades a whole list. */
void pf_display_append_faded(pf_display *d, const pf_display *src, float dx, float dy, float alpha);

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
