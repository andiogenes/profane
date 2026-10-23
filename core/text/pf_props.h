#ifndef PF_PROPS_H
#define PF_PROPS_H

#include <stddef.h>
#include <stdint.h>

/* Text properties: for each property (a small integer id), a sorted list of non-overlapping
 * runs giving a 32-bit value to a range of character positions. Value 0 means "no property".
 * Adjacent runs with equal values are merged. Edits move runs as Emacs moves text properties:
 * text inserted by a plain insert has no properties (a run it lands inside is split), deleted
 * text takes its properties with it.
 *
 * Runs live in arrays, so an edit costs O(runs after it). Fine for now; a tree can replace the
 * arrays behind this API once highlighting makes runs dense (M5). */

enum { PF_PROPS_MAX = 32 }; /* property ids 1..PF_PROPS_MAX-1 */

typedef struct pf_prop_run {
    size_t start, end;
    uint32_t value;
} pf_prop_run;

typedef struct pf_props pf_props;

pf_props *pf_props_new(void);
void pf_props_free(pf_props *p);

/* Gives [START, END) value VALUE for PROP (0 removes it). Returns -1 for a bad prop id. */
int pf_props_put(pf_props *p, uint32_t prop, size_t start, size_t end, uint32_t value);

/* Value of PROP at POS (0 if none). */
uint32_t pf_props_get(const pf_props *p, uint32_t prop, size_t pos);

/* Runs of PROP overlapping [START, END), clipped to it, in order. Writes up to CAP into OUT and
 * returns the total count. */
size_t pf_props_runs(const pf_props *p, uint32_t prop, size_t start, size_t end, pf_prop_run *out,
                     size_t cap);

/* Bumped by every put, so displays know to render again (edits change the text snapshot). */
uint64_t pf_props_generation(const pf_props *p);

/* Edit adjustments: N characters inserted at POS; characters [START, END) deleted. */
void pf_props_insert(pf_props *p, size_t pos, size_t n);
void pf_props_delete(pf_props *p, size_t start, size_t end);

#endif
