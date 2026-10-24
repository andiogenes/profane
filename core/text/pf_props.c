#include "pf_props.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct run_list {
    pf_prop_run *r;
    size_t n, cap;
} run_list;

struct pf_props {
    run_list lists[PF_PROPS_MAX];
    uint64_t generation;
};

uint64_t pf_props_generation(const pf_props *p) {
    return p->generation;
}

static void *xrealloc(void *p, size_t size) {
    p = realloc(p, size ? size : 1);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

pf_props *pf_props_new(void) {
    pf_props *p = xrealloc(NULL, sizeof *p);
    memset(p, 0, sizeof *p);
    return p;
}

void pf_props_free(pf_props *p) {
    if (p) {
        for (int i = 0; i < PF_PROPS_MAX; i++) {
            free(p->lists[i].r);
        }
        free(p);
    }
}

/* Index of the first run whose end is > POS (binary search). */
static size_t first_ending_after(const run_list *l, size_t pos) {
    size_t lo = 0, hi = l->n;
    while (lo < hi) {
        size_t mid = (lo + hi) / 2;
        if (l->r[mid].end <= pos) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

static void insert_at(run_list *l, size_t i, pf_prop_run run) {
    if (l->n == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 16;
        l->r = xrealloc(l->r, l->cap * sizeof *l->r);
    }
    memmove(l->r + i + 1, l->r + i, (l->n - i) * sizeof *l->r);
    l->r[i] = run;
    l->n++;
}

static void remove_range(run_list *l, size_t i, size_t count) {
    if (count == 0) {
        return; /* the list may still be empty (NULL): no pointer arithmetic on it */
    }
    memmove(l->r + i, l->r + i + count, (l->n - i - count) * sizeof *l->r);
    l->n -= count;
}

/* Merges run I with equal-valued, touching neighbours. */
static void coalesce(run_list *l, size_t i) {
    if (i + 1 < l->n && l->r[i].end == l->r[i + 1].start && l->r[i].value == l->r[i + 1].value) {
        l->r[i].end = l->r[i + 1].end;
        remove_range(l, i + 1, 1);
    }
    if (i > 0 && i < l->n && l->r[i - 1].end == l->r[i].start &&
        l->r[i - 1].value == l->r[i].value) {
        l->r[i - 1].end = l->r[i].end;
        remove_range(l, i, 1);
    }
}

/* Removes PROP from [START, END), splitting runs at the edges. Returns where [START, END)
 * would be inserted. */
static size_t clear_range(run_list *l, size_t start, size_t end) {
    size_t i = first_ending_after(l, start);
    if (i < l->n && l->r[i].start < start) {
        pf_prop_run left = l->r[i];
        left.end = start;
        l->r[i].start = start;
        insert_at(l, i, left);
        i++;
    }
    size_t j = i;
    while (j < l->n && l->r[j].end <= end) {
        j++;
    }
    if (j < l->n && l->r[j].start < end) {
        l->r[j].start = end; /* trim the run straddling END */
    }
    remove_range(l, i, j - i);
    return i;
}

int pf_props_put(pf_props *p, uint32_t prop, size_t start, size_t end, uint32_t value) {
    if (prop == 0 || prop >= PF_PROPS_MAX) {
        return -1;
    }
    if (start >= end) {
        return 0;
    }
    p->generation++;
    run_list *l = &p->lists[prop];
    size_t i = clear_range(l, start, end);
    if (value) {
        insert_at(l, i, (pf_prop_run){start, end, value});
        coalesce(l, i);
    }
    return 0;
}

uint32_t pf_props_get(const pf_props *p, uint32_t prop, size_t pos) {
    if (prop == 0 || prop >= PF_PROPS_MAX) {
        return 0;
    }
    const run_list *l = &p->lists[prop];
    size_t i = first_ending_after(l, pos);
    return i < l->n && l->r[i].start <= pos ? l->r[i].value : 0;
}

size_t pf_props_runs(const pf_props *p, uint32_t prop, size_t start, size_t end, pf_prop_run *out,
                     size_t cap) {
    if (prop == 0 || prop >= PF_PROPS_MAX || start >= end) {
        return 0;
    }
    const run_list *l = &p->lists[prop];
    size_t count = 0;
    for (size_t i = first_ending_after(l, start); i < l->n && l->r[i].start < end; i++) {
        if (count < cap) {
            pf_prop_run r = l->r[i];
            r.start = r.start < start ? start : r.start;
            r.end = r.end > end ? end : r.end;
            out[count] = r;
        }
        count++;
    }
    return count;
}

void pf_props_insert(pf_props *p, size_t pos, size_t n) {
    if (n == 0) {
        return;
    }
    for (int k = 1; k < PF_PROPS_MAX; k++) {
        run_list *l = &p->lists[k];
        size_t i = first_ending_after(l, pos);
        if (i < l->n && l->r[i].start < pos) {
            /* Inserted inside a run: split it; the new text has no properties. */
            pf_prop_run right = l->r[i];
            right.start = pos;
            l->r[i].end = pos;
            insert_at(l, i + 1, right);
            i++;
        }
        for (; i < l->n; i++) {
            l->r[i].start += n;
            l->r[i].end += n;
        }
    }
}

void pf_props_delete(pf_props *p, size_t start, size_t end) {
    if (start >= end) {
        return;
    }
    size_t n = end - start;
    for (int k = 1; k < PF_PROPS_MAX; k++) {
        run_list *l = &p->lists[k];
        size_t i = clear_range(l, start, end);
        for (size_t j = i; j < l->n; j++) {
            l->r[j].start -= n;
            l->r[j].end -= n;
        }
        if (i < l->n) {
            coalesce(l, i); /* the runs on both sides of the deletion now touch */
        }
    }
}
