#include "pf_display.h"

#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>

struct pf_display {
    atomic_size_t refs;
    int frozen;
    float width, height, scale;
    uint32_t clear;
    pf_display_item *items;
    size_t count, cap;
};

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

pf_display *pf_display_new(float width, float height, float scale, uint32_t clear) {
    pf_display *d = xrealloc(NULL, sizeof *d);
    atomic_init(&d->refs, 1);
    d->frozen = 0;
    d->width = width;
    d->height = height;
    d->scale = scale;
    d->clear = clear;
    d->items = NULL;
    d->count = d->cap = 0;
    return d;
}

static pf_display_item *push(pf_display *d) {
    assert(!d->frozen);
    if (d->count == d->cap) {
        d->cap = d->cap ? d->cap * 2 : 256;
        d->items = xrealloc(d->items, d->cap * sizeof *d->items);
    }
    return &d->items[d->count++];
}

void pf_display_rect(pf_display *d, float x, float y, float w, float h, uint32_t color) {
    if (w <= 0 || h <= 0 || (color & 0xFF) == 0) {
        return;
    }
    pf_display_item *it = push(d);
    it->kind = PF_DISPLAY_RECT;
    it->color = color;
    it->x = x;
    it->y = y;
    it->u.rect.w = w;
    it->u.rect.h = h;
}

void pf_display_round_rect(pf_display *d, float x, float y, float w, float h, float radius,
                           float line, uint32_t color) {
    if (w <= 0 || h <= 0 || (color & 0xFF) == 0) {
        return;
    }
    float max = (w < h ? w : h) / 2;
    pf_display_item *it = push(d);
    it->kind = PF_DISPLAY_ROUND_RECT;
    it->color = color;
    it->x = x;
    it->y = y;
    it->u.round.w = w;
    it->u.round.h = h;
    it->u.round.radius = radius < 0 ? 0 : radius > max ? max : radius;
    it->u.round.extra = line < 0 ? 0 : line;
}

void pf_display_shadow(pf_display *d, float x, float y, float w, float h, float radius, float blur,
                       uint32_t color) {
    if (w <= 0 || h <= 0 || blur <= 0 || (color & 0xFF) == 0) {
        return;
    }
    float max = (w < h ? w : h) / 2;
    pf_display_item *it = push(d);
    it->kind = PF_DISPLAY_SHADOW;
    it->color = color;
    it->x = x;
    it->y = y;
    it->u.round.w = w;
    it->u.round.h = h;
    it->u.round.radius = radius < 0 ? 0 : radius > max ? max : radius;
    it->u.round.extra = blur;
}

void pf_display_glyph(pf_display *d, uint32_t font, uint32_t glyph, float x, float baseline,
                      uint32_t color) {
    pf_display_item *it = push(d);
    it->kind = PF_DISPLAY_GLYPH;
    it->color = color;
    it->x = x;
    it->y = baseline;
    it->u.glyph.font = font;
    it->u.glyph.glyph = glyph;
}

void pf_display_append(pf_display *d, const pf_display *src, float dx, float dy) {
    for (size_t i = 0; i < src->count; i++) {
        pf_display_item *it = push(d);
        *it = src->items[i];
        it->x += dx;
        it->y += dy;
    }
}

const pf_display *pf_display_finish(pf_display *d) {
    d->frozen = 1;
    return d;
}

const pf_display *pf_display_retain(const pf_display *d) {
    atomic_fetch_add_explicit(&((pf_display *)d)->refs, 1, memory_order_relaxed);
    return d;
}

void pf_display_release(const pf_display *d) {
    pf_display *m = (pf_display *)d;
    if (m && atomic_fetch_sub_explicit(&m->refs, 1, memory_order_acq_rel) == 1) {
        free(m->items);
        free(m);
    }
}

float pf_display_width(const pf_display *d) {
    return d->width;
}

float pf_display_height(const pf_display *d) {
    return d->height;
}

float pf_display_scale(const pf_display *d) {
    return d->scale;
}

uint32_t pf_display_clear(const pf_display *d) {
    return d->clear;
}

size_t pf_display_count(const pf_display *d) {
    return d->count;
}

const pf_display_item *pf_display_items(const pf_display *d) {
    return d->items;
}
