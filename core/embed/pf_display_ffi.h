#ifndef PF_DISPLAY_FFI_H
#define PF_DISPLAY_FFI_H

#include <stddef.h>
#include <stdint.h>

#include "pf_handles.h"

/* Faces and text properties for Scheme's `foreign-procedure` (conventions: pf_buffer_ffi.h).
 * Main thread only. */

/* Defines face ID: FLAGS are PF_FACE_* (pf_face.h); FONT 0 means the window's default font. */
void pf_face_define(uint32_t id, uint32_t flags, uint32_t fg, uint32_t bg, uint32_t underline,
                    uint32_t font);
void pf_face_role_set(int role, uint32_t id);
uint32_t pf_face_default_background(void); /* the default face's background, for the shell */

int pf_buf_put_prop(pf_handle buf, uint32_t prop, size_t start, size_t end, uint32_t value);
int64_t pf_buf_get_prop(pf_handle buf, uint32_t prop, size_t pos); /* -2 for a bad handle */

#endif
