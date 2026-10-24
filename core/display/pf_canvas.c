#include "pf_canvas.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_face.h"

typedef enum op_kind {
    OP_RECT,
    OP_ROUND_RECT,
    OP_SHADOW,
    OP_TEXT,
} op_kind;

typedef struct op {
    op_kind kind;
    float x, y, w, h, radius, extra; /* extra: outline width or blur */
    uint32_t color;
    uint32_t face;
    size_t text, ntext; /* into the code point pool */
} op;

typedef struct hit {
    float x, y, w, h;
    uint32_t id;
    int cursor;
} hit;

struct pf_canvas {
    float width, height;
    uint64_t version;
    op *ops;
    size_t nops, capops;
    uint32_t *pool;
    size_t npool, cappool;
    hit *hits;
    size_t nhits, caphits;
};

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size ? size : 1);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

pf_canvas *pf_canvas_new(float width, float height) {
    pf_canvas *c = xrealloc(NULL, sizeof *c);
    memset(c, 0, sizeof *c);
    c->width = width;
    c->height = height;
    return c;
}

void pf_canvas_free(pf_canvas *c) {
    if (c) {
        free(c->ops);
        free(c->pool);
        free(c->hits);
        free(c);
    }
}

void pf_canvas_set_size(pf_canvas *c, float width, float height) {
    if (c->width != width || c->height != height) {
        c->width = width;
        c->height = height;
        c->version++;
    }
}

float pf_canvas_width(const pf_canvas *c) {
    return c->width;
}

float pf_canvas_height(const pf_canvas *c) {
    return c->height;
}

uint64_t pf_canvas_version(const pf_canvas *c) {
    return c->version;
}

void pf_canvas_clear(pf_canvas *c) {
    c->nops = c->npool = c->nhits = 0;
    c->version++;
}

static op *push_op(pf_canvas *c, op_kind kind, float x, float y, float w, float h, uint32_t color) {
    if (c->nops == c->capops) {
        c->capops = c->capops ? c->capops * 2 : 32;
        c->ops = xrealloc(c->ops, c->capops * sizeof *c->ops);
    }
    op *o = &c->ops[c->nops++];
    memset(o, 0, sizeof *o);
    o->kind = kind;
    o->x = x;
    o->y = y;
    o->w = w;
    o->h = h;
    o->color = color;
    c->version++;
    return o;
}

void pf_canvas_fill_rect(pf_canvas *c, float x, float y, float w, float h, uint32_t color) {
    push_op(c, OP_RECT, x, y, w, h, color);
}

void pf_canvas_fill_round_rect(pf_canvas *c, float x, float y, float w, float h, float radius,
                               uint32_t color) {
    push_op(c, OP_ROUND_RECT, x, y, w, h, color)->radius = radius;
}

void pf_canvas_stroke_round_rect(pf_canvas *c, float x, float y, float w, float h, float radius,
                                 float line, uint32_t color) {
    op *o = push_op(c, OP_ROUND_RECT, x, y, w, h, color);
    o->radius = radius;
    o->extra = line > 0 ? line : 1;
}

void pf_canvas_shadow(pf_canvas *c, float x, float y, float w, float h, float radius, float blur,
                      uint32_t color) {
    op *o = push_op(c, OP_SHADOW, x, y, w, h, color);
    o->radius = radius;
    o->extra = blur;
}

void pf_canvas_line(pf_canvas *c, float x0, float y0, float x1, float y1, float line,
                    uint32_t color) {
    float lo_x = fminf(x0, x1), lo_y = fminf(y0, y1);
    float w = fabsf(x1 - x0), h = fabsf(y1 - y0);
    if (w >= h) { /* horizontal: LINE thick, centered on the segment */
        push_op(c, OP_RECT, lo_x, lo_y - line / 2, w, line, color);
    } else {
        push_op(c, OP_RECT, lo_x - line / 2, lo_y, line, h, color);
    }
}

void pf_canvas_text(pf_canvas *c, float x, float y, const uint32_t *cps, size_t n, uint32_t face,
                    uint32_t color) {
    if (c->npool + n > c->cappool) {
        c->cappool = (c->npool + n) * 2 + 64;
        c->pool = xrealloc(c->pool, c->cappool * sizeof *c->pool);
    }
    op *o = push_op(c, OP_TEXT, x, y, 0, 0, color);
    o->face = face;
    o->text = c->npool;
    o->ntext = n;
    if (n) {
        memcpy(c->pool + c->npool, cps, n * sizeof *cps);
    }
    c->npool += n;
}

void pf_canvas_add_hit(pf_canvas *c, float x, float y, float w, float h, uint32_t id, int cursor) {
    if (c->nhits == c->caphits) {
        c->caphits = c->caphits ? c->caphits * 2 : 8;
        c->hits = xrealloc(c->hits, c->caphits * sizeof *c->hits);
    }
    c->hits[c->nhits++] = (hit){x, y, w, h, id, cursor};
    c->version++;
}

int64_t pf_canvas_hit_test(const pf_canvas *c, float x, float y, int *cursor) {
    for (size_t i = c->nhits; i-- > 0;) {
        const hit *h = &c->hits[i];
        if (x >= h->x && x < h->x + h->w && y >= h->y && y < h->y + h->h) {
            if (cursor) {
                *cursor = h->cursor;
            }
            return h->id;
        }
    }
    return -1;
}

/* ---- text ---- */

static uint32_t face_font(uint32_t face, uint32_t fallback) {
    uint32_t f = pf_face_get(face)->font;
    return f ? f : fallback;
}

void pf_canvas_text_extent(const pf_canvas_env *env, const uint32_t *cps, size_t n, uint32_t face,
                           float *width, float *height) {
    uint32_t font = face_font(face, env->default_font);
    pf_font_metrics m = pf_font_source_metrics(env->fonts, font);
    if (height) {
        *height = ceilf(m.ascent + m.descent + m.leading);
    }
    if (width) {
        *width = n ? pf_layout_line(env->cache, font, cps, n)->width : 0;
    }
}

void pf_canvas_render(const pf_canvas *c, pf_display *d, const pf_canvas_env *env, float dx,
                      float dy) {
    for (size_t i = 0; i < c->nops; i++) {
        const op *o = &c->ops[i];
        float x = o->x + dx, y = o->y + dy;
        switch (o->kind) {
        case OP_RECT:
            pf_display_rect(d, x, y, o->w, o->h, o->color);
            break;
        case OP_ROUND_RECT:
            pf_display_round_rect(d, x, y, o->w, o->h, o->radius, o->extra, o->color);
            break;
        case OP_SHADOW:
            pf_display_shadow(d, x, y, o->w, o->h, o->radius, o->extra, o->color);
            break;
        case OP_TEXT: {
            if (o->ntext == 0) {
                break;
            }
            uint32_t font = face_font(o->face, env->default_font);
            const pf_face *f = pf_face_get(o->face);
            const pf_face *def = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT));
            uint32_t fg = (o->color & 0xFF) ? o->color
                          : (f->flags & PF_FACE_HAS_FG) ? f->fg
                          : (def->flags & PF_FACE_HAS_FG) ? def->fg
                                                          : 0x000000FF;
            const pf_line_layout *lay = pf_layout_line(env->cache, font, c->pool + o->text, o->ntext);
            float baseline = y + roundf(pf_font_source_metrics(env->fonts, font).ascent);
            for (size_t g = 0; g < lay->nglyphs; g++) {
                pf_display_glyph(d, lay->glyphs[g].font, lay->glyphs[g].glyph, x + lay->glyphs[g].x,
                                 baseline, fg);
            }
            break;
        }
        }
    }
}
