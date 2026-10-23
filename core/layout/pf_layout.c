#include "pf_layout.h"

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

struct pf_shaped {
    pf_shaped_glyph *g;
    size_t n, cap;
};

typedef struct entry {
    uint64_t hash;
    pf_font_run *runs;
    size_t nruns;
    uint32_t *cps;
    size_t n;
    pf_line_layout layout;
    uint64_t frame;              /* last frame that used it */
    struct entry *prev, *next;   /* LRU list, most recent first */
    struct entry *chain;         /* hash bucket */
} entry;

struct pf_layout_cache {
    pf_shaper shaper;
    size_t capacity;
    int tab_width;
    entry **buckets;
    size_t nbuckets, count;
    entry *head, *tail;
    uint64_t frame;
    pf_shaped scratch;
    pf_layout_stats stats;
};

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size ? size : 1);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

void pf_shaped_push(pf_shaped *out, uint32_t font, uint32_t glyph, float x, uint32_t cluster) {
    if (out->n == out->cap) {
        out->cap = out->cap ? out->cap * 2 : 64;
        out->g = xrealloc(out->g, out->cap * sizeof *out->g);
    }
    out->g[out->n++] = (pf_shaped_glyph){font, glyph, x, cluster};
}

static uint64_t hash_line(const pf_font_run *runs, size_t nruns, const uint32_t *cps, size_t n) {
    uint64_t h = 1469598103934665603ull; /* FNV-1a over fonts, run lengths and code points */
    for (size_t r = 0; r < nruns; r++) {
        h ^= runs[r].font;
        h *= 1099511628211ull;
        h ^= runs[r].len;
        h *= 1099511628211ull;
    }
    for (size_t i = 0; i < n; i++) {
        h ^= cps[i];
        h *= 1099511628211ull;
    }
    return h ^ (uint64_t)n;
}

static int same_runs(const entry *e, const pf_font_run *runs, size_t nruns) {
    if (e->nruns != nruns) {
        return 0;
    }
    for (size_t r = 0; r < nruns; r++) {
        if (e->runs[r].font != runs[r].font || e->runs[r].len != runs[r].len) {
            return 0;
        }
    }
    return 1;
}

pf_layout_cache *pf_layout_cache_new(pf_shaper shaper, size_t capacity, int tab_width) {
    pf_layout_cache *c = xrealloc(NULL, sizeof *c);
    memset(c, 0, sizeof *c);
    c->shaper = shaper;
    c->capacity = capacity ? capacity : 1;
    c->tab_width = tab_width > 0 ? tab_width : 8;
    c->nbuckets = 1024;
    while (c->nbuckets < c->capacity * 2) {
        c->nbuckets *= 2;
    }
    c->buckets = xrealloc(NULL, c->nbuckets * sizeof *c->buckets);
    memset(c->buckets, 0, c->nbuckets * sizeof *c->buckets);
    return c;
}

static void entry_free(entry *e) {
    free(e->cps);
    free(e->runs);
    free((void *)e->layout.glyphs);
    free((void *)e->layout.caret_x);
    free(e);
}

static void lru_unlink(pf_layout_cache *c, entry *e) {
    if (e->prev) {
        e->prev->next = e->next;
    } else {
        c->head = e->next;
    }
    if (e->next) {
        e->next->prev = e->prev;
    } else {
        c->tail = e->prev;
    }
    e->prev = e->next = NULL;
}

static void lru_push_front(pf_layout_cache *c, entry *e) {
    e->prev = NULL;
    e->next = c->head;
    if (c->head) {
        c->head->prev = e;
    }
    c->head = e;
    if (!c->tail) {
        c->tail = e;
    }
}

static void remove_entry(pf_layout_cache *c, entry *e) {
    entry **link = &c->buckets[e->hash & (c->nbuckets - 1)];
    while (*link != e) {
        link = &(*link)->chain;
    }
    *link = e->chain;
    lru_unlink(c, e);
    c->count--;
    entry_free(e);
}

void pf_layout_cache_clear(pf_layout_cache *c) {
    while (c->head) {
        remove_entry(c, c->head);
    }
}

void pf_layout_cache_free(pf_layout_cache *c) {
    if (c) {
        pf_layout_cache_clear(c);
        free(c->buckets);
        free(c->scratch.g);
        free(c);
    }
}

void pf_layout_begin_frame(pf_layout_cache *c) {
    c->frame++;
    /* Everything is from an earlier frame now, so the LRU tail can go. */
    while (c->count > c->capacity && c->tail) {
        remove_entry(c, c->tail);
        c->stats.evictions++;
    }
}

/* Shapes CPS (tabs expanded) into E's layout, one segment per font run and tab. */
static void shape_into(pf_layout_cache *c, entry *e, const pf_font_run *runs, size_t nruns,
                       const uint32_t *cps, size_t n) {
    pf_shaped *out = &c->scratch;
    out->n = 0;
    float *caret = xrealloc(NULL, (n + 1) * sizeof *caret);
    for (size_t i = 0; i <= n; i++) {
        caret[i] = NAN;
    }
    float x = 0;
    size_t run = 0, run_end = nruns ? runs[0].start + runs[0].len : n;
    uint32_t font = nruns ? runs[0].font : 0;
    size_t start = 0;
    for (size_t i = 0; i <= n; i++) {
        int boundary = i == n || cps[i] == '\t' || i == run_end;
        if (!boundary) {
            continue;
        }
        if (i > start) {
            size_t before = out->n;
            float advance = c->shaper.shape(c->shaper.ctx, font, cps + start, i - start, out);
            for (size_t g = before; g < out->n; g++) {
                out->g[g].x += x;
                out->g[g].cluster += (uint32_t)start;
            }
            x += advance;
        }
        start = i;
        if (i == run_end && run + 1 < nruns) { /* next font run */
            run++;
            font = runs[run].font;
            run_end = runs[run].start + runs[run].len;
        }
        if (i < n && cps[i] == '\t') { /* a tab: caret before it, then jump to the next stop */
            caret[i] = x;
            float stop = c->shaper.cell_width(c->shaper.ctx, font) * (float)c->tab_width;
            x = stop > 0 ? (floorf(x / stop + 1e-4f) + 1) * stop : x;
            start = i + 1;
        }
    }

    /* Caret of a character: leftmost glyph of its cluster. Characters inside a multi-character
     * cluster (ligatures, combining marks) get evenly interpolated positions. */
    for (size_t g = 0; g < out->n; g++) {
        uint32_t k = out->g[g].cluster;
        if (k < n && (isnan(caret[k]) || out->g[g].x < caret[k])) {
            caret[k] = out->g[g].x;
        }
    }
    caret[0] = isnan(caret[0]) ? 0 : caret[0];
    caret[n] = x;
    for (size_t i = 1; i < n;) {
        if (!isnan(caret[i])) {
            i++;
            continue;
        }
        size_t j = i;
        while (isnan(caret[j])) {
            j++;
        }
        float a = caret[i - 1], step = (caret[j] - a) / (float)(j - i + 1);
        for (size_t k = i; k < j; k++) {
            caret[k] = a + step * (float)(k - i + 1);
        }
        i = j;
    }

    pf_shaped_glyph *glyphs = xrealloc(NULL, out->n * sizeof *glyphs);
    memcpy(glyphs, out->g, out->n * sizeof *glyphs);
    e->layout = (pf_line_layout){glyphs, out->n, caret, n, x};
}

const pf_line_layout *pf_layout_line(pf_layout_cache *c, uint32_t font, const uint32_t *cps,
                                     size_t n) {
    pf_font_run run = {0, n, font};
    return pf_layout_line_runs(c, &run, 1, cps, n);
}

const pf_line_layout *pf_layout_line_runs(pf_layout_cache *c, const pf_font_run *runs,
                                          size_t nruns, const uint32_t *cps, size_t n) {
    uint64_t h = hash_line(runs, nruns, cps, n);
    entry **bucket = &c->buckets[h & (c->nbuckets - 1)];
    for (entry *e = *bucket; e; e = e->chain) {
        if (e->hash == h && e->n == n && same_runs(e, runs, nruns) &&
            (n == 0 || memcmp(e->cps, cps, n * sizeof *cps) == 0)) {
            lru_unlink(c, e);
            lru_push_front(c, e);
            e->frame = c->frame;
            c->stats.hits++;
            return &e->layout;
        }
    }
    entry *e = xrealloc(NULL, sizeof *e);
    memset(e, 0, sizeof *e);
    e->hash = h;
    e->runs = xrealloc(NULL, nruns * sizeof *runs);
    memcpy(e->runs, runs, nruns * sizeof *runs);
    e->nruns = nruns;
    e->n = n;
    e->cps = xrealloc(NULL, n * sizeof *cps);
    memcpy(e->cps, cps, n * sizeof *cps);
    e->frame = c->frame;
    shape_into(c, e, runs, nruns, cps, n);
    e->chain = *bucket;
    *bucket = e;
    lru_push_front(c, e);
    c->count++;
    c->stats.misses++;
    return &e->layout;
}

pf_layout_stats pf_layout_cache_stats(const pf_layout_cache *c) {
    pf_layout_stats s = c->stats;
    s.entries = c->count;
    return s;
}
