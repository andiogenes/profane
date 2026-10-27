#include "pf_frame.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_anim.h"
#include "pf_face.h"

typedef struct entry {
    pf_window *w;
    uint32_t tag;
    float x, y, width, height;
    int shown;
    float text_scale;
    const pf_display *last; /* the window's newest list */
    /* The rect drawn, which springs to the placed one (animate-windows); at rest it is equal. */
    pf_spring ax, ay, aw, ah;
    int rect_init, fresh; /* drawn rect valid; added and not yet placed */
} entry;

typedef struct popup {
    pf_canvas *canvas;
    float x, y;
    uint64_t seen; /* canvas version last drawn */
    const pf_display *list; /* its canvas rendered at (0, 0), kept while pop-ups animate */
    pf_spring a;            /* opacity, 0..1 (animate-popups) */
} popup;

/* A pop-up that was hidden, fading out. */
typedef struct ghost {
    const pf_display *list;
    float x, y;
    pf_spring a;
} ghost;

enum { RECT_OMEGA = 30, POPUP_OMEGA = 35, POPUP_SLIDE = 6 };

struct pf_frame {
    pf_layout_cache *cache;
    pf_font_source fonts;
    int has_fonts;
    uint32_t base_font;
    float width, height, scale;
    entry *entries;
    size_t count, cap;
    pf_window *selected;
    pf_strip tab_bar;
    uint64_t style_generation; /* face generation the window styles follow */
    int dirty;
    popup *popups; /* bottom first */
    size_t npopups, cappopups;
    int overlay_dirty;
    uint64_t native_generation;
    ghost *ghosts;
    size_t nghosts, capghosts;
    double anim_time; /* of the last step; 0: the next tick starts an animation */
    int snap;         /* the frame was resized: placements this round take effect at once */
};

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size ? size : 1);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

pf_frame *pf_frame_new(pf_layout_cache *cache, const pf_font_source *fonts, uint32_t base_font) {
    pf_frame *f = xrealloc(NULL, sizeof *f);
    memset(f, 0, sizeof *f);
    f->cache = cache;
    if (fonts) {
        f->fonts = *fonts;
        f->has_fonts = 1;
    }
    f->base_font = base_font;
    f->scale = 1;
    f->dirty = 1;
    return f;
}

void pf_frame_free(pf_frame *f) {
    if (!f) {
        return;
    }
    for (size_t i = 0; i < f->count; i++) {
        pf_display_release(f->entries[i].last);
        pf_window_free(f->entries[i].w);
    }
    for (size_t i = 0; i < f->npopups; i++) {
        pf_display_release(f->popups[i].list);
    }
    for (size_t i = 0; i < f->nghosts; i++) {
        pf_display_release(f->ghosts[i].list);
    }
    free(f->entries);
    free(f->popups);
    free(f->ghosts);
    pf_strip_free(&f->tab_bar);
    free(f);
}

static const pf_font_source *fonts_of(const pf_frame *f) {
    return f->has_fonts ? &f->fonts : NULL;
}

static entry *find(pf_frame *f, const pf_window *w) {
    for (size_t i = 0; i < f->count; i++) {
        if (f->entries[i].w == w) {
            return &f->entries[i];
        }
    }
    return NULL;
}

pf_window_style pf_frame_text_style(const pf_frame *f, float factor) {
    uint32_t font = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT))->font;
    font = font ? font : f->base_font;
    pf_font_metrics m =
        pf_font_source_metrics(fonts_of(f), pf_font_source_scaled(fonts_of(f), font, factor));
    /* Whole-point line boxes keep rows pixel-aligned at every scale. */
    return (pf_window_style){
        .font = f->base_font,
        .ascent = roundf(m.ascent),
        .descent = m.descent,
        .line_height = ceilf(m.ascent + m.descent + m.leading + pf_display_line_spacing()),
        .cell_width = m.advance,
        .pad_left = 0,
        .pad_top = 2,
    };
}

float pf_frame_strip_height(const pf_frame *f, uint32_t face, uint32_t box) {
    uint32_t font = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT))->font;
    return pf_strip_height(fonts_of(f), face, font ? font : f->base_font, box);
}

static void restyle(pf_frame *f, entry *e) {
    pf_window_style st = pf_frame_text_style(f, e->text_scale);
    pf_window_set_style(e->w, &st);
}

void pf_frame_set_size(pf_frame *f, float width, float height, float scale) {
    if (width != f->width || height != f->height || scale != f->scale) {
        f->width = width;
        f->height = height;
        f->scale = scale;
        for (size_t i = 0; i < f->count; i++) {
            entry *e = &f->entries[i];
            pf_window_set_size(e->w, e->width, e->height, scale);
        }
        f->dirty = 1;
        f->overlay_dirty = 1;
        f->snap = 1;
    }
}

float pf_frame_width(const pf_frame *f) {
    return f->width;
}

float pf_frame_height(const pf_frame *f) {
    return f->height;
}

pf_window *pf_frame_add_window(pf_frame *f, uint32_t tag) {
    if (f->count == f->cap) {
        f->cap = f->cap ? f->cap * 2 : 8;
        f->entries = xrealloc(f->entries, f->cap * sizeof *f->entries);
    }
    pf_window_style st = pf_frame_text_style(f, 1);
    entry *e = &f->entries[f->count++];
    memset(e, 0, sizeof *e);
    e->w = pf_window_new(f->cache, &st);
    e->tag = tag;
    e->text_scale = 1;
    e->fresh = 1;
    pf_window_set_fonts(e->w, fonts_of(f));
    return e->w;
}

int pf_frame_remove_window(pf_frame *f, pf_window *w) {
    entry *e = find(f, w);
    if (!e) {
        return -1;
    }
    if (pf_window_native(e->w)) {
        f->native_generation++;
    }
    pf_display_release(e->last);
    pf_window_free(e->w);
    *e = f->entries[--f->count];
    if (f->selected == w) {
        f->selected = NULL;
    }
    f->dirty = 1;
    return 0;
}

size_t pf_frame_window_count(const pf_frame *f) {
    return f->count;
}

uint32_t pf_frame_window_tag(const pf_frame *f, size_t i) {
    return i < f->count ? f->entries[i].tag : 0;
}

void pf_frame_set_window_tag(pf_frame *f, pf_window *w, uint32_t tag) {
    entry *e = find(f, w);
    if (e) {
        e->tag = tag;
    }
}

static void rect_snap(entry *e) {
    pf_spring_snap(&e->ax, e->x);
    pf_spring_snap(&e->ay, e->y);
    pf_spring_snap(&e->aw, e->width);
    pf_spring_snap(&e->ah, e->height);
    e->rect_init = 1;
}

static int rect_moving(const entry *e) {
    return e->rect_init && e->shown &&
           (!pf_spring_settled(&e->ax, 0.25f) || !pf_spring_settled(&e->ay, 0.25f) ||
            !pf_spring_settled(&e->aw, 0.25f) || !pf_spring_settled(&e->ah, 0.25f));
}

static int near(float a, float b) {
    return a - b < 1 && b - a < 1;
}

/* A window just placed at its rect: slide the drawn rect there. A new window grows out of the
 * one it was split from (stacked: from its top edge; side by side: from its left); resizing the
 * frame, tab switches and native views take effect at once. */
static void rect_animate(pf_frame *f, entry *e, int was_shown) {
    int fresh = e->fresh;
    if (e->shown) {
        e->fresh = 0;
    }
    if (!e->shown || f->snap || pf_window_native(e->w) || !pf_motion_feature_on(PF_MOTION_WINDOWS)) {
        rect_snap(e);
        return;
    }
    if (!e->rect_init || !was_shown) {
        rect_snap(e);
        if (fresh) {
            for (size_t i = 0; i < f->count; i++) {
                const entry *o = &f->entries[i];
                if (o == e || !o->shown || !o->rect_init) {
                    continue;
                }
                if (near(o->ax.value, e->x) && near(o->aw.value, e->width)) {
                    pf_spring_snap(&e->ah, 0);
                    e->ah.target = e->height;
                    return;
                }
                if (near(o->ay.value, e->y) && near(o->ah.value, e->height)) {
                    pf_spring_snap(&e->aw, 0);
                    e->aw.target = e->width;
                    return;
                }
            }
        }
        return;
    }
    e->ax.target = e->x;
    e->ay.target = e->y;
    e->aw.target = e->width;
    e->ah.target = e->height;
}

int pf_frame_place_window(pf_frame *f, pf_window *w, float x, float y, float width, float height,
                          int shown) {
    entry *e = find(f, w);
    if (!e) {
        return -1;
    }
    shown = shown != 0;
    if (x != e->x || y != e->y || width != e->width || height != e->height ||
        shown != e->shown) {
        if (shown && !e->shown) {
            pf_window_invalidate(w); /* its last list may predate changes made while hidden */
        }
        int was_shown = e->shown;
        e->x = x;
        e->y = y;
        e->width = width;
        e->height = height;
        e->shown = shown;
        pf_window_set_size(w, width, height, f->scale);
        rect_animate(f, e, was_shown);
        f->dirty = 1;
        if (pf_window_native(w)) {
            f->native_generation++;
        }
    }
    return 0;
}

int pf_frame_set_window_native(pf_frame *f, pf_window *w, uint32_t kind) {
    entry *e = find(f, w);
    if (!e) {
        return -1;
    }
    if (pf_window_native(w) != kind) {
        pf_window_set_native(w, kind);
        f->native_generation++;
        f->dirty = 1;
    }
    return 0;
}

uint64_t pf_frame_native_generation(const pf_frame *f) {
    return f->native_generation;
}

size_t pf_frame_native_count(const pf_frame *f) {
    size_t n = 0;
    for (size_t i = 0; i < f->count; i++) {
        n += pf_window_native(f->entries[i].w) != 0;
    }
    return n;
}

int pf_frame_native_get(const pf_frame *f, size_t i, pf_native_placement *out) {
    for (size_t k = 0; k < f->count; k++) {
        const entry *e = &f->entries[k];
        if (!pf_window_native(e->w)) {
            continue;
        }
        if (i-- == 0) {
            float r[4];
            pf_window_body_rect(e->w, r);
            *out = (pf_native_placement){e->tag, pf_window_native(e->w), e->x + r[0], e->y + r[1],
                                         r[2], r[3], e->shown};
            return 0;
        }
    }
    return -1;
}

int pf_frame_set_text_scale(pf_frame *f, pf_window *w, float factor) {
    entry *e = find(f, w);
    if (!e || !(factor > 0)) {
        return -1;
    }
    if (factor != e->text_scale) {
        e->text_scale = factor;
        pf_window_set_text_scale(w, factor);
        restyle(f, e);
    }
    return 0;
}

void pf_frame_select(pf_frame *f, pf_window *w) {
    f->selected = w && find(f, w) ? w : NULL;
}

pf_window *pf_frame_selected(const pf_frame *f) {
    return f->selected;
}

void pf_frame_set_tab_bar(pf_frame *f, const uint32_t *cps, size_t n, const pf_strip_run *runs,
                          size_t nruns, uint32_t face, uint32_t box) {
    if (pf_strip_set(&f->tab_bar, cps, n, runs, nruns, face, box)) {
        f->dirty = 1;
    }
}

static int popups_moving(const pf_frame *f) {
    for (size_t i = 0; i < f->npopups; i++) {
        if (!pf_spring_settled(&f->popups[i].a, 0.01f)) {
            return 1;
        }
    }
    return f->nghosts > 0;
}

static int rects_moving(const pf_frame *f) {
    for (size_t i = 0; i < f->count; i++) {
        if (rect_moving(&f->entries[i])) {
            return 1;
        }
    }
    return 0;
}

static void rects_snap_all(pf_frame *f) {
    for (size_t i = 0; i < f->count; i++) {
        if (f->entries[i].rect_init) {
            rect_snap(&f->entries[i]);
        }
    }
}

static void ghost_free_at(pf_frame *f, size_t i) {
    pf_display_release(f->ghosts[i].list);
    f->ghosts[i] = f->ghosts[--f->nghosts];
}

void pf_frame_tick(pf_frame *f, double now) {
    for (size_t i = 0; i < f->count; i++) {
        if (f->entries[i].shown) {
            pf_window_tick(f->entries[i].w, now);
        }
    }
    if (!rects_moving(f) && !popups_moving(f)) {
        f->anim_time = 0;
        return;
    }
    double dt = f->anim_time == 0 ? 1.0 / 120 : now - f->anim_time;
    f->anim_time = now;
    /* Late frame, or the features were switched off: everything arrives now. */
    int late = dt > 0.05;
    if (late || !pf_motion_feature_on(PF_MOTION_WINDOWS)) {
        rects_snap_all(f);
    } else {
        for (size_t i = 0; i < f->count; i++) {
            entry *e = &f->entries[i];
            if (rect_moving(e)) {
                pf_spring_step(&e->ax, RECT_OMEGA, (float)dt);
                pf_spring_step(&e->ay, RECT_OMEGA, (float)dt);
                pf_spring_step(&e->aw, RECT_OMEGA, (float)dt);
                pf_spring_step(&e->ah, RECT_OMEGA, (float)dt);
                if (!rect_moving(e)) {
                    rect_snap(e);
                }
            }
        }
    }
    int popups = late || !pf_motion_feature_on(PF_MOTION_POPUPS);
    for (size_t i = 0; i < f->npopups; i++) {
        popup *p = &f->popups[i];
        if (popups) {
            pf_spring_snap(&p->a, p->a.target);
        } else {
            pf_spring_step(&p->a, POPUP_OMEGA, (float)dt);
            if (pf_spring_settled(&p->a, 0.01f)) {
                pf_spring_snap(&p->a, p->a.target);
            }
        }
    }
    for (size_t i = f->nghosts; i-- > 0;) {
        pf_spring_step(&f->ghosts[i].a, POPUP_OMEGA, (float)dt);
        if (popups || pf_spring_settled(&f->ghosts[i].a, 0.01f)) {
            ghost_free_at(f, i);
        }
    }
    f->dirty = 1;
    f->overlay_dirty = 1;
}

int pf_frame_animating(const pf_frame *f) {
    if (rects_moving(f) || popups_moving(f)) {
        return 1;
    }
    for (size_t i = 0; i < f->count; i++) {
        if (f->entries[i].shown && pf_window_animating(f->entries[i].w)) {
            return 1;
        }
    }
    return 0;
}

const pf_display *pf_frame_redisplay(pf_frame *f) {
    if (pf_face_generation() != f->style_generation) {
        /* Faces changed (theme, font, line spacing): the default font's metrics may have. */
        f->style_generation = pf_face_generation();
        for (size_t i = 0; i < f->count; i++) {
            restyle(f, &f->entries[i]);
        }
        f->dirty = 1;
    }
    int changed = f->dirty;
    for (size_t i = 0; i < f->count; i++) {
        entry *e = &f->entries[i];
        if (!e->shown) {
            continue;
        }
        const pf_display *d = pf_window_redisplay(e->w);
        if (d) {
            pf_display_release(e->last);
            e->last = d;
            changed = 1;
        }
    }
    f->snap = 0;
    if (!changed) {
        return NULL;
    }
    f->dirty = 0;
    const pf_face *def = pf_face_get(pf_face_role_id(PF_ROLE_DEFAULT));
    uint32_t bg = def->flags & PF_FACE_HAS_BG ? def->bg : 0xFFFFFFFF;
    pf_display *d = pf_display_new(f->width, f->height, f->scale, bg);
    for (size_t i = 0; i < f->count; i++) {
        entry *e = &f->entries[i];
        if (e->shown && e->last) {
            if (rect_moving(e)) {
                /* Content keeps its placed size and is revealed through the sliding rect. */
                pf_display_clip(d, e->ax.value, e->ay.value, e->aw.value, e->ah.value);
                pf_display_append(d, e->last, e->ax.value, e->ay.value);
                pf_display_unclip(d);
            } else {
                pf_display_append(d, e->last, e->x, e->y);
            }
        }
    }
    if (f->tab_bar.face) {
        uint32_t font = def->font ? def->font : f->base_font;
        pf_layout_begin_frame(f->cache);
        pf_strip_render(&f->tab_bar, d, f->cache, fonts_of(f), font, 0, 0, f->width,
                        pf_frame_strip_height(f, f->tab_bar.face, f->tab_bar.box), f->scale);
    }
    return pf_display_finish(d);
}

int pf_frame_cursor_rect(const pf_frame *f, float rect[4]) {
    entry *e = f->selected ? find((pf_frame *)f, f->selected) : NULL;
    if (!e || !e->shown || pf_window_cursor_rect(e->w, rect) != 0) {
        return -1;
    }
    rect[0] += e->x;
    rect[1] += e->y;
    return 0;
}

/* ---- pop-up surfaces ---- */

static popup *find_popup(const pf_frame *f, const pf_canvas *c) {
    for (size_t i = 0; i < f->npopups; i++) {
        if (f->popups[i].canvas == c) {
            return &f->popups[i];
        }
    }
    return NULL;
}

void pf_frame_popup_show(pf_frame *f, pf_canvas *c, float x, float y) {
    popup *p = find_popup(f, c);
    if (!p) {
        if (f->npopups == f->cappopups) {
            f->cappopups = f->cappopups ? f->cappopups * 2 : 8;
            f->popups = xrealloc(f->popups, f->cappopups * sizeof *f->popups);
        }
        p = &f->popups[f->npopups++];
        p->canvas = c;
        p->seen = 0;
        p->x = p->y = 0;
        p->list = NULL;
        pf_spring_snap(&p->a, 1);
        if (!f->snap && pf_motion_feature_on(PF_MOTION_POPUPS)) {
            p->a.value = 0; /* fades in */
        }
        f->overlay_dirty = 1;
    }
    if (p->x != x || p->y != y) {
        p->x = x;
        p->y = y;
        f->overlay_dirty = 1;
    }
}

int pf_frame_popup_hide(pf_frame *f, pf_canvas *c) {
    popup *p = find_popup(f, c);
    if (!p) {
        return -1;
    }
    if (p->list && pf_motion_feature_on(PF_MOTION_POPUPS) && !f->snap) {
        /* Fades out from the last thing shown, which the canvas may not outlive. */
        if (f->nghosts == f->capghosts) {
            f->capghosts = f->capghosts ? f->capghosts * 2 : 4;
            f->ghosts = xrealloc(f->ghosts, f->capghosts * sizeof *f->ghosts);
        }
        ghost *g = &f->ghosts[f->nghosts++];
        g->list = p->list;
        p->list = NULL;
        g->x = p->x;
        g->y = p->y;
        g->a = p->a;
        g->a.target = 0;
    }
    pf_display_release(p->list);
    memmove(p, p + 1, (size_t)(f->popups + f->npopups - p - 1) * sizeof *p);
    f->npopups--;
    f->overlay_dirty = 1;
    return 0;
}

int pf_frame_popup_shown(const pf_frame *f, const pf_canvas *c, float *x, float *y) {
    popup *p = find_popup(f, c);
    if (!p) {
        return 0;
    }
    if (x) {
        *x = p->x;
    }
    if (y) {
        *y = p->y;
    }
    return 1;
}

static pf_canvas_env canvas_env(pf_frame *f) {
    return (pf_canvas_env){f->cache, f->has_fonts ? &f->fonts : NULL, f->base_font};
}

void pf_frame_text_extent(pf_frame *f, const uint32_t *cps, size_t n, uint32_t face, float *width,
                          float *height) {
    pf_canvas_env env = canvas_env(f);
    pf_canvas_text_extent(&env, cps, n, face, width, height);
}

const pf_display *pf_frame_redisplay_overlay(pf_frame *f) {
    int changed = f->overlay_dirty;
    int use_lists = pf_motion_feature_on(PF_MOTION_POPUPS);
    for (size_t i = 0; i < f->npopups; i++) {
        changed |= f->popups[i].seen != pf_canvas_version(f->popups[i].canvas);
    }
    if (!changed) {
        return NULL;
    }
    f->overlay_dirty = 0;
    pf_canvas_env env = canvas_env(f);
    pf_display *d = pf_display_new(f->width, f->height, f->scale, 0);
    for (size_t i = 0; i < f->npopups; i++) {
        popup *p = &f->popups[i];
        if (!use_lists && p->a.value >= 1) {
            pf_display_release(p->list);
            p->list = NULL;
            p->seen = pf_canvas_version(p->canvas);
            pf_canvas_render(p->canvas, d, &env, p->x, p->y);
            continue;
        }
        /* Animating: render the canvas on its own, then draw that faded and slid. */
        if (!p->list || p->seen != pf_canvas_version(p->canvas)) {
            pf_display_release(p->list);
            pf_display *own = pf_display_new(f->width, f->height, f->scale, 0);
            pf_canvas_render(p->canvas, own, &env, 0, 0);
            p->list = pf_display_finish(own);
            p->seen = pf_canvas_version(p->canvas);
        }
        pf_display_append_faded(d, p->list, p->x, p->y + (1 - p->a.value) * POPUP_SLIDE,
                                p->a.value);
    }
    for (size_t i = 0; i < f->nghosts; i++) {
        const ghost *g = &f->ghosts[i];
        pf_display_append_faded(d, g->list, g->x, g->y + (1 - g->a.value) * POPUP_SLIDE,
                                g->a.value);
    }
    return pf_display_finish(d);
}

int64_t pf_frame_hit_test_at(const pf_frame *f, float x, float y, pf_canvas **canvas, int *cursor,
                             float *lx, float *ly) {
    for (size_t i = f->npopups; i-- > 0;) {
        const popup *p = &f->popups[i];
        int64_t id = pf_canvas_hit_test(p->canvas, x - p->x, y - p->y, cursor);
        if (id >= 0) {
            if (canvas) {
                *canvas = p->canvas;
            }
            if (lx) {
                *lx = x - p->x;
            }
            if (ly) {
                *ly = y - p->y;
            }
            return id;
        }
    }
    for (size_t i = 0; i < f->count; i++) {
        const entry *e = &f->entries[i];
        pf_canvas *c = pf_window_canvas(e->w);
        if (!c || !e->shown) {
            continue;
        }
        float r[4];
        pf_window_body_rect(e->w, r);
        float cx = x - e->x - r[0], cy = y - e->y - r[1];
        if (cx < 0 || cy < 0 || cx >= r[2] || cy >= r[3]) {
            continue;
        }
        int64_t id = pf_canvas_hit_test(c, cx, cy, cursor);
        if (id >= 0) {
            if (canvas) {
                *canvas = c;
            }
            if (lx) {
                *lx = cx;
            }
            if (ly) {
                *ly = cy;
            }
            return id;
        }
    }
    return -1;
}

int64_t pf_frame_hit_test(const pf_frame *f, float x, float y, pf_canvas **canvas, int *cursor) {
    return pf_frame_hit_test_at(f, x, y, canvas, cursor, NULL, NULL);
}

int pf_frame_cursor_at(const pf_frame *f, float x, float y) {
    int cursor = 0;
    if (pf_frame_hit_test_at(f, x, y, NULL, &cursor, NULL, NULL) >= 0) {
        return cursor;
    }
    for (size_t i = 0; i < f->count; i++) {
        const entry *e = &f->entries[i];
        if (!e->shown || pf_window_native(e->w) || pf_window_canvas(e->w)) {
            continue;
        }
        float r[4];
        pf_window_body_rect(e->w, r);
        float lx = x - e->x - r[0], ly = y - e->y - r[1];
        if (lx >= 0 && ly >= 0 && lx < r[2] && ly < r[3]) {
            return 2;
        }
    }
    return 0;
}

int pf_frame_set_window_canvas(pf_frame *f, pf_window *w, pf_canvas *c) {
    entry *e = find(f, w);
    if (!e) {
        return -1;
    }
    pf_window_set_canvas(w, c);
    f->dirty = 1;
    return 0;
}

void pf_frame_detach_canvas(pf_frame *f, pf_canvas *c) {
    for (size_t i = 0; i < f->count; i++) {
        if (pf_window_canvas(f->entries[i].w) == c) {
            pf_window_set_canvas(f->entries[i].w, NULL);
            f->dirty = 1;
        }
    }
}

int pf_frame_set_window_terminal(pf_frame *f, pf_window *w, pf_term *t, const uint32_t faces[4]) {
    entry *e = find(f, w);
    if (!e) {
        return -1;
    }
    pf_window_set_terminal(w, t, faces);
    f->dirty = 1;
    return 0;
}

void pf_frame_detach_terminal(pf_frame *f, pf_term *t) {
    for (size_t i = 0; i < f->count; i++) {
        if (pf_window_terminal(f->entries[i].w) == t) {
            pf_window_set_terminal(f->entries[i].w, NULL, NULL);
            f->dirty = 1;
        }
    }
}
