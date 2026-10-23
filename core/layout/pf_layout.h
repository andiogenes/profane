#ifndef PF_LAYOUT_H
#define PF_LAYOUT_H

#include <stddef.h>
#include <stdint.h>

/* Line layout cache. A line (a run of characters without '\n') is shaped into positioned
 * glyphs plus a caret x for every character boundary. Results are cached by content — font
 * and code points — so an edit only misses for the lines it changed and identical lines share
 * one layout. Main thread only.
 *
 * Shaping itself (fonts, ligatures, fallback) is the platform's job, behind pf_shaper; tabs are
 * expanded here, to stops every TAB_WIDTH cells of the font's '0' advance. */

typedef struct pf_shaped_glyph {
    uint32_t font;  /* pf_font_id: may differ from the requested font (fallback) */
    uint32_t glyph;
    float x;        /* pen position relative to the line start, points */
    uint32_t cluster; /* index of the first character this glyph belongs to */
} pf_shaped_glyph;

/* Shaper output buffer, owned by the cache; the shaper appends with pf_shaped_push. */
typedef struct pf_shaped pf_shaped;
void pf_shaped_push(pf_shaped *out, uint32_t font, uint32_t glyph, float x, uint32_t cluster);

typedef struct pf_shaper {
    void *ctx;
    /* Shapes code points CPS[0..N) with FONT starting at x = 0, appending glyphs to OUT, and
     * returns the total advance. Cluster indices are relative to CPS. */
    float (*shape)(void *ctx, uint32_t font, const uint32_t *cps, size_t n, pf_shaped *out);
    /* Advance of one cell ('0') of FONT. */
    float (*cell_width)(void *ctx, uint32_t font);
} pf_shaper;

typedef struct pf_line_layout {
    const pf_shaped_glyph *glyphs;
    size_t nglyphs;
    const float *caret_x; /* nchars + 1 entries: x of each character boundary */
    size_t nchars;
    float width;
} pf_line_layout;

typedef struct pf_layout_cache pf_layout_cache;

pf_layout_cache *pf_layout_cache_new(pf_shaper shaper, size_t capacity, int tab_width);
void pf_layout_cache_free(pf_layout_cache *cache);

/* Marks the start of a frame. Layouts returned during a frame stay valid until the next
 * pf_layout_begin_frame; only lines not used in the current frame are evicted. */
void pf_layout_begin_frame(pf_layout_cache *cache);

/* Layout of the line CPS[0..N) in FONT (no '\n'). */
const pf_line_layout *pf_layout_line(pf_layout_cache *cache, uint32_t font, const uint32_t *cps,
                                     size_t n);

/* Drops every entry, e.g. after a font or tab-width change. */
void pf_layout_cache_clear(pf_layout_cache *cache);

typedef struct pf_layout_stats {
    size_t entries, hits, misses, evictions;
} pf_layout_stats;
pf_layout_stats pf_layout_cache_stats(const pf_layout_cache *cache);

#endif
