#ifndef PF_GIT_FFI_H
#define PF_GIT_FFI_H

#include <stddef.h>
#include <stdint.h>

#include "pf_handles.h"

/* pf_git_line_marks (pf_git.h) for the text buffer BUF as it is now, against the file PATH[0..LEN).
 * OUT receives CAP triples of uint32 (line, count, kind); returns the number of marks, -1 if PATH
 * is not tracked, or -2 for a bad handle. */
int64_t pf_git_buffer_marks(pf_handle buf, const char *path, size_t len, uint32_t *out, size_t cap);

#endif
