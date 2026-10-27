#include "pf_strip.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_face.h"

/* Vertical padding above and below the text, and the text's left inset, in points. */
enum { PAD_Y = 2, PAD_X = 6 };

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size ? size : 1);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

pf_font_metrics pf_font_source_metrics(const pf_font_source *src, uint32_t font) {
    pf_font_metrics m = {15, 5, 0, 10}; /* the fixed shaper: 10-point cells, 20-point lines */
    if (src && src->metrics) {
        pf_font_metrics got;
        if (src->metrics(src->ctx, font, &got) == 0) {
            m = got;
        }
    }
    return m;
}

uint32_t pf_font_source_scaled(const pf_font_source *src, uint32_t font, float factor) {
    if (factor == 1.0f || !src || !src->scaled) {
        return font;
    }
    uint32_t scaled = src->scaled(src->ctx, font, factor);
    return scaled ? scaled : font;
}

int pf_strip_set(pf_strip *s, const uint32_t *cps, size_t n, const pf_strip_run *runs,
                 size_t nruns, uint32_t face, uint32_t box) {
    if (!face) {
        n = nruns = 0;
        box = 0;
    }
    if (s->face == face && s->box == box && s->n == n && s->nruns == nruns &&
        (n == 0 || memcmp(s->cps, cps, n * sizeof *cps) == 0) &&
        (nruns == 0 || memcmp(s->runs, runs, nruns * sizeof *runs) == 0)) {
        return 0;
    }
    s->cps = xrealloc(s->cps, n * sizeof *cps);
    if (n) {
        memcpy(s->cps, cps, n * sizeof *cps);
    }
    s->runs = xrealloc(s->runs, nruns * sizeof *runs);
    if (nruns) {
        memcpy(s->runs, runs, nruns * sizeof *runs);
    }
    s->n = n;
    s->nruns = nruns;
    s->face = face;
    s->box = box;
    return 1;
}

void pf_strip_free(pf_strip *s) {
    free(s->cps);
    free(s->runs);
    memset(s, 0, sizeof *s);
}

static uint32_t face_font(uint32_t face, uint32_t fallback) {
    uint32_t f = pf_face_get(face)->font;
    return f ? f : fallback;
}

float pf_strip_height(const pf_font_source *src, uint32_t face, uint32_t default_font, uint32_t box) {
    pf_font_metrics m = pf_font_source_metrics(src, face_font(face, default_font));
    return ceilf(m.ascent + m.descent + m.leading) + 2 * PAD_Y + (box ? 2 : 0);
}

/* sRGBA C moved toward white (AMOUNT > 0) or black (< 0). */
static uint32_t shade(uint32_t c, float amount) {
    uint32_t out = c & 0xFF;
    for (int shift = 8; shift < 32; shift += 8) {
        float v = (float)((c >> shift) & 0xFF);
        v = amount > 0 ? v + (255 - v) * amount : v * (1 + amount);
        out |= (uint32_t)lroundf(v) << shift;
    }
    return out;
}

/* The box: a border color's top and bottom lines, or a raised strip's light and dark edges. */
static void draw_edges(const pf_strip *s, const pf_face *base, pf_display *d, float x, float y,
                       float w, float h, float scale) {
    float px = 1.0f / scale;
    if (s->box > 1) {
        pf_display_rect(d, x, y, w, px, s->box);
        pf_display_rect(d, x, y + h - px, w, px, s->box);
    } else if (s->box && (base->flags & PF_FACE_HAS_BG)) {
        pf_display_rect(d, x, y, w, px, shade(base->bg, 0.5f));
        pf_display_rect(d, x, y + h - px, w, px, shade(base->bg, -0.25f));
    }
}

void pf_strip_render(const pf_strip *s, pf_display *d, pf_layout_cache *cache,
                     const pf_font_source *src, uint32_t default_font, float x, float y, float w,
                     float h, float scale) {
    if (!s->face || w <= 0 || h <= 0) {
        return;
    }
    const pf_face *base = pf_face_get(s->face);
    uint32_t base_font = face_font(s->face, default_font);
    const pf_face *def = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT));
    uint32_t base_fg = base->flags & PF_FACE_HAS_FG ? base->fg
                       : def->flags & PF_FACE_HAS_FG ? def->fg
                                                     : 0x000000FF;
    if (base->flags & PF_FACE_HAS_BG) {
        pf_display_rect(d, x, y, w, h, base->bg);
    }
    if (s->n == 0) {
        draw_edges(s, base, d, x, y, w, h, scale);
        return;
    }

    /* Face and font of every character, then one font run per change. */
    uint32_t *fids = xrealloc(NULL, s->n * sizeof *fids);
    for (size_t i = 0; i < s->n; i++) {
        fids[i] = s->face;
    }
    for (size_t r = 0; r < s->nruns; r++) {
        for (size_t i = s->runs[r].start; i < s->runs[r].end && i < s->n; i++) {
            fids[i] = s->runs[r].face;
        }
    }
    pf_font_run *runs = xrealloc(NULL, s->n * sizeof *runs);
    size_t nruns = 0;
    for (size_t i = 0; i < s->n; i++) {
        uint32_t f = face_font(fids[i], base_font);
        if (nruns && runs[nruns - 1].font == f) {
            runs[nruns - 1].len++;
        } else {
            runs[nruns++] = (pf_font_run){i, 1, f};
        }
    }
    const pf_line_layout *lay = pf_layout_line_runs(cache, runs, nruns, s->cps, s->n);
    pf_font_metrics m = pf_font_source_metrics(src, base_font);
    float x0 = x + PAD_X, right = x + w;
    float baseline = y + (s->box ? 1 : 0) + PAD_Y + roundf(m.ascent);

    for (size_t i = 0; i < s->n;) { /* run backgrounds */
        size_t j = i + 1;
        while (j < s->n && fids[j] == fids[i]) {
            j++;
        }
        const pf_face *f = pf_face_get(fids[i]);
        if (fids[i] != s->face && (f->flags & PF_FACE_HAS_BG)) {
            float rx = x0 + lay->caret_x[i], rw = fminf(lay->caret_x[j] + x0, right) - rx;
            pf_display_rect(d, rx, y, rw, h, f->bg);
        }
        i = j;
    }
    draw_edges(s, base, d, x, y, w, h, scale); /* over the run backgrounds */
    for (size_t g = 0; g < lay->nglyphs; g++) {
        const pf_shaped_glyph *sg = &lay->glyphs[g];
        size_t c = sg->cluster < lay->nchars ? sg->cluster : lay->nchars - 1;
        if (x0 + lay->caret_x[c + 1] > right + 0.5f) {
            continue; /* would cross the right edge */
        }
        const pf_face *f = pf_face_get(fids[c]);
        uint32_t color = f->flags & PF_FACE_HAS_FG ? f->fg : base_fg;
        pf_display_glyph(d, sg->font, sg->glyph, x0 + sg->x, baseline, color);
    }
    free(runs);
    free(fids);
}
