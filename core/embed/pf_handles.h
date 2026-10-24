#ifndef PF_HANDLES_H
#define PF_HANDLES_H

#include <stdint.h>

/* Integer handles for C objects exposed to Scheme, which never sees pointers. A handle encodes
 * a slot, a generation (so a freed handle stays invalid when its slot is reused) and the object
 * kind (so a handle of one kind is never accepted as another). 0 is never valid. Main thread
 * only. */

typedef uint32_t pf_handle;

typedef enum pf_handle_kind {
    PF_HANDLE_TEXT = 1,
    PF_HANDLE_WINDOW = 2,
    PF_HANDLE_FRAME = 3,
} pf_handle_kind;

pf_handle pf_handle_new(pf_handle_kind kind, void *object); /* 0 if out of memory or slots */
void *pf_handle_get(pf_handle handle, pf_handle_kind kind); /* NULL if invalid */
/* Invalidates HANDLE and returns its object (NULL if invalid); the caller frees the object. */
void *pf_handle_free(pf_handle handle, pf_handle_kind kind);

#endif
