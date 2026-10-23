#ifndef PF_FONT_H
#define PF_FONT_H

#include <stdint.h>

/* Font registry: fonts are integer ids so display lists stay plain data. Implemented by the
 * platform (Core Text). Ids are never reused; opening is main-thread only, lookups (by the
 * render thread) are thread-safe. */

typedef uint32_t pf_font_id;

typedef struct pf_font_metrics {
    float ascent, descent, leading; /* points; descent is positive */
    float advance;                  /* advance of '0', the cell width for monospace fonts */
} pf_font_metrics;

/* Opens FAMILY at SIZE points, falling back to the system monospaced font if FAMILY is not
 * installed. Returns 0 on failure. Opening the same family and size twice returns one id. */
pf_font_id pf_font_open(const char *family, float size);

/* FAMILY (NULL: the system monospaced font) at SIZE with bold/italic traits where the family
 * has them. Returns 0 on failure. */
pf_font_id pf_font_open_styled(const char *family, float size, int bold, int italic);

/* Like pf_font_open_styled; FAMILY "system-ui" is the macOS UI font (SF Pro), and FEATURES
 * (NULL or e.g. "calt=0,liga=0") sets OpenType features. Fonts differing only in features get
 * different ids. */
pf_font_id pf_font_open_ex(const char *family, float size, int bold, int italic,
                           const char *features);

/* Returns 0, or -1 for an unknown id. */
int pf_font_metrics_get(pf_font_id font, pf_font_metrics *out);

#endif
