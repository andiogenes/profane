#include "pf_handles.h"

#include <stdlib.h>

/* Layout: | kind:4 | gen:8 | slot+1:20 | */
enum { SLOT_BITS = 20, GEN_BITS = 8, KIND_SHIFT = SLOT_BITS + GEN_BITS };
#define SLOT_MASK ((1u << SLOT_BITS) - 1)
#define GEN_MASK ((1u << GEN_BITS) - 1)

typedef struct entry {
    void *object;
    uint8_t gen, kind; /* kind 0: free */
} entry;

static entry *entries;
static uint32_t count, cap, free_hint;

static pf_handle encode(uint32_t slot, const entry *e) {
    return (uint32_t)e->kind << KIND_SHIFT | (uint32_t)e->gen << SLOT_BITS | (slot + 1);
}

static entry *lookup(pf_handle h, pf_handle_kind kind) {
    uint32_t slot = h & SLOT_MASK;
    if (slot == 0 || slot > count) {
        return NULL;
    }
    entry *e = &entries[slot - 1];
    if (e->kind == 0 || e->kind != kind || (h >> KIND_SHIFT) != (uint32_t)kind ||
        ((h >> SLOT_BITS) & GEN_MASK) != e->gen) {
        return NULL;
    }
    return e;
}

pf_handle pf_handle_new(pf_handle_kind kind, void *object) {
    uint32_t slot = free_hint;
    while (slot < count && entries[slot].kind != 0) {
        slot++;
    }
    if (slot == count) {
        if (count == SLOT_MASK) {
            return 0;
        }
        if (count == cap) {
            uint32_t ncap = cap ? cap * 2 : 64;
            entry *grown = realloc(entries, ncap * sizeof *grown);
            if (!grown) {
                return 0;
            }
            entries = grown;
            cap = ncap;
        }
        entries[count++] = (entry){NULL, 0, 0};
    }
    entry *e = &entries[slot];
    e->object = object;
    e->kind = (uint8_t)kind;
    free_hint = slot + 1;
    return encode(slot, e);
}

void *pf_handle_get(pf_handle handle, pf_handle_kind kind) {
    entry *e = lookup(handle, kind);
    return e ? e->object : NULL;
}

void *pf_handle_free(pf_handle handle, pf_handle_kind kind) {
    entry *e = lookup(handle, kind);
    if (!e) {
        return NULL;
    }
    void *object = e->object;
    e->object = NULL;
    e->kind = 0;
    e->gen = (uint8_t)((e->gen + 1) & GEN_MASK);
    uint32_t slot = (uint32_t)(e - entries);
    if (slot < free_hint) {
        free_hint = slot;
    }
    return object;
}
