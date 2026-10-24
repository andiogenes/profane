#include "pf_boxdraw.h"

#include <math.h>

/* Arms of U+2500..257F, 2 bits each: left, right, up, down (0 none, 1 light, 2 heavy, 3 double).
 * Generated from the Unicode names; 0 marks characters not drawn here (the diagonals). */
static const uint8_t arms[128] = {0x05, 0x0A, 0x50, 0xA0, 0x05, 0x0A, 0x50, 0xA0, 0x05, 0x0A, 0x50, 0xA0, 0x44, 0x48, 0x84, 0x88, 0x41, 0x42, 0x81, 0x82, 0x14, 0x18, 0x24, 0x28, 0x11, 0x12, 0x21, 0x22, 0x54, 0x58, 0x64, 0x94, 0xA4, 0x68, 0x98, 0xA8, 0x51, 0x52, 0x61, 0x91, 0xA1, 0x62, 0x92, 0xA2, 0x45, 0x46, 0x49, 0x4A, 0x85, 0x86, 0x89, 0x8A, 0x15, 0x16, 0x19, 0x1A, 0x25, 0x26, 0x29, 0x2A, 0x55, 0x56, 0x59, 0x5A, 0x65, 0x95, 0xA5, 0x66, 0x69, 0x96, 0x99, 0x6A, 0x9A, 0xA6, 0xA9, 0xAA, 0x05, 0x0A, 0x50, 0xA0, 0x0F, 0xF0, 0x4C, 0xC4, 0xCC, 0x43, 0xC1, 0xC3, 0x1C, 0x34, 0x3C, 0x13, 0x31, 0x33, 0x5C, 0xF4, 0xFC, 0x53, 0xF1, 0xF3, 0x4F, 0xC5, 0xCF, 0x1F, 0x35, 0x3F, 0x5F, 0xF5, 0xFF, 0x44, 0x41, 0x11, 0x14, 0x00, 0x00, 0x00, 0x01, 0x10, 0x04, 0x40, 0x02, 0x20, 0x08, 0x80, 0x09, 0x90, 0x06, 0x60};

static float maxf(float a, float b) { return a > b ? a : b; }

/* A horizontal (HORIZ) or vertical stroke of weight WEIGHT through the cell's middle, from FROM to TO
 * along the stroke and T thick; double strokes are two thin ones. */
static void stroke(pf_display *d, int horiz, int weight, float from, float to, float cx, float cy,
                   float t, uint32_t color) {
    float thick = weight == 2 ? 2 * t : t;
    float offsets[2] = {0, 0};
    int n = 1;
    if (weight == 3) {
        offsets[0] = -t;
        offsets[1] = t;
        n = 2;
    }
    for (int i = 0; i < n; i++) {
        if (horiz) {
            pf_display_rect(d, from, cy - thick / 2 + offsets[i], to - from, thick, color);
        } else {
            pf_display_rect(d, cx - thick / 2 + offsets[i], from, thick, to - from, color);
        }
    }
}

static int draw_lines(pf_display *d, uint32_t cp, float x, float y, float w, float h,
                      uint32_t color) {
    uint8_t a = arms[cp - 0x2500];
    if (a == 0) {
        return 0;
    }
    int l = a & 3, r = (a >> 2) & 3, u = (a >> 4) & 3, dn = (a >> 6) & 3;
    float t = maxf(1.0f, roundf(w / 8));
    float cx = x + roundf(w / 2), cy = y + roundf(h / 2);
    /* arms reach past the middle by half the thickest stroke, so corners and tees are filled */
    int heaviest = 1;
    int ws[4] = {l, r, u, dn};
    for (int i = 0; i < 4; i++) {
        if (ws[i] == 2) {
            heaviest = 2;
        }
        if (ws[i] == 3 && heaviest < 3) {
            heaviest = 3;
        }
    }
    float reach = (heaviest == 2 ? 2 * t : heaviest == 3 ? 3 * t : t) / 2;
    if (l && l == r) { /* one stroke across */
        stroke(d, 1, l, x, x + w, cx, cy, t, color);
    } else {
        if (l) {
            stroke(d, 1, l, x, cx + reach, cx, cy, t, color);
        }
        if (r) {
            stroke(d, 1, r, cx - reach, x + w, cx, cy, t, color);
        }
    }
    if (u && u == dn) {
        stroke(d, 0, u, y, y + h, cx, cy, t, color);
    } else {
        if (u) {
            stroke(d, 0, u, y, cy + reach, cx, cy, t, color);
        }
        if (dn) {
            stroke(d, 0, dn, cy - reach, y + h, cx, cy, t, color);
        }
    }
    return 1;
}

static uint32_t with_alpha(uint32_t color, uint32_t alpha) {
    return (color & 0xFFFFFF00u) | ((color & 0xFF) * alpha / 255);
}

static int draw_block(pf_display *d, uint32_t cp, float x, float y, float w, float h,
                      uint32_t color) {
    float hw = roundf(w / 2), hh = roundf(h / 2);
    if (cp == 0x2580) { /* upper half */
        pf_display_rect(d, x, y, w, hh, color);
    } else if (cp >= 0x2581 && cp <= 0x2588) { /* lower 1/8 .. 8/8 */
        float f = roundf(h * (float)(cp - 0x2580) / 8);
        pf_display_rect(d, x, y + h - f, w, f, color);
    } else if (cp >= 0x2589 && cp <= 0x258F) { /* left 7/8 .. 1/8 */
        pf_display_rect(d, x, y, roundf(w * (float)(0x2590 - cp) / 8), h, color);
    } else if (cp == 0x2590) { /* right half */
        pf_display_rect(d, x + hw, y, w - hw, h, color);
    } else if (cp >= 0x2591 && cp <= 0x2593) { /* light, medium, dark shade */
        pf_display_rect(d, x, y, w, h, with_alpha(color, 64u * (uint32_t)(cp - 0x2590)));
    } else if (cp == 0x2594) { /* upper 1/8 */
        pf_display_rect(d, x, y, w, roundf(h / 8), color);
    } else if (cp == 0x2595) { /* right 1/8 */
        float f = roundf(w / 8);
        pf_display_rect(d, x + w - f, y, f, h, color);
    } else if (cp >= 0x2596 && cp <= 0x259F) { /* quadrants: UL UR LL LR bits */
        static const uint8_t quad[10] = {0x4, 0x8, 0x1, 0xD, 0x9, 0x7, 0xB, 0x2, 0x6, 0xE};
        uint8_t q = quad[cp - 0x2596];
        if (q & 1) {
            pf_display_rect(d, x, y, hw, hh, color);
        }
        if (q & 2) {
            pf_display_rect(d, x + hw, y, w - hw, hh, color);
        }
        if (q & 4) {
            pf_display_rect(d, x, y + hh, hw, h - hh, color);
        }
        if (q & 8) {
            pf_display_rect(d, x + hw, y + hh, w - hw, h - hh, color);
        }
    } else {
        return 0;
    }
    return 1;
}

int pf_boxdraw(pf_display *d, uint32_t cp, float x, float y, float w, float h, uint32_t color) {
    if (cp >= 0x2500 && cp <= 0x257F) {
        return draw_lines(d, cp, x, y, w, h, color);
    }
    if (cp >= 0x2580 && cp <= 0x259F) {
        return draw_block(d, cp, x, y, w, h, color);
    }
    return 0;
}
