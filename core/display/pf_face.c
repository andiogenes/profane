#include "pf_face.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static pf_face *faces;
static uint32_t face_cap;
static uint32_t roles[PF_ROLE_COUNT];
static uint64_t generation = 1;
static const pf_face empty_face;

void pf_face_set(uint32_t id, const pf_face *face) {
    if (id >= face_cap) {
        uint32_t cap = id + 64;
        pf_face *grown = realloc(faces, cap * sizeof *grown);
        if (!grown) {
            fputs("profane: out of memory\n", stderr);
            abort();
        }
        memset(grown + face_cap, 0, (cap - face_cap) * sizeof *grown);
        faces = grown;
        face_cap = cap;
    }
    faces[id] = *face;
    generation++;
}

const pf_face *pf_face_get(uint32_t id) {
    return id < face_cap ? &faces[id] : &empty_face;
}

void pf_face_set_role(pf_face_role role, uint32_t id) {
    if (role < PF_ROLE_COUNT) {
        roles[role] = id;
        generation++;
    }
}

uint32_t pf_face_role_id(pf_face_role role) {
    return role < PF_ROLE_COUNT ? roles[role] : 0;
}

uint64_t pf_face_generation(void) {
    return generation;
}
