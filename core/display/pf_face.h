#ifndef PF_FACE_H
#define PF_FACE_H

#include <stdint.h>

/* Resolved faces for the display engine: the C side of (profane face). Scheme resolves
 * inheritance and pushes each face's final attributes here by id; the display engine reads
 * them while rendering. Main thread only. */

enum {
    PF_FACE_HAS_FG = 1 << 0,
    PF_FACE_HAS_BG = 1 << 1,
    PF_FACE_UNDERLINE = 1 << 2,
};

typedef struct pf_face {
    uint32_t flags;
    uint32_t fg, bg;          /* 0xRRGGBBAA, valid per flags */
    uint32_t underline_color; /* 0: use fg */
    uint32_t font;            /* pf_font_id; 0: the window's default font */
} pf_face;

/* Faces the display engine itself draws with, mapped to face ids by Scheme. */
typedef enum pf_face_role {
    PF_ROLE_DEFAULT,
    PF_ROLE_CURSOR,
    PF_ROLE_LINE_NUMBER,
    PF_ROLE_LINE_NUMBER_CURRENT,
    PF_ROLE_HL_LINE,
    PF_ROLE_PAREN_MATCH,
    PF_ROLE_PAREN_MISMATCH,
    PF_ROLE_FRINGE,          /* background of the fringes */
    PF_ROLE_VERTICAL_BORDER, /* foreground of the divider between side-by-side windows */
    PF_ROLE_COUNT
} pf_face_role;

/* Defines or redefines face ID (ids are small integers chosen by Scheme). */
void pf_face_set(uint32_t id, const pf_face *face);
/* Face ID, or an empty face (no colors, default font) if unknown. */
const pf_face *pf_face_get(uint32_t id);

void pf_face_set_role(pf_face_role role, uint32_t id);
uint32_t pf_face_role_id(pf_face_role role);

/* Extra space between lines, in points (Emacs line-spacing); part of the face generation. */
void pf_display_set_line_spacing(float points);
float pf_display_line_spacing(void);

/* Bumped on every change, so windows know to render again. */
uint64_t pf_face_generation(void);

#endif
