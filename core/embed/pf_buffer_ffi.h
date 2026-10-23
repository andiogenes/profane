#ifndef PF_BUFFER_FFI_H
#define PF_BUFFER_FFI_H

#include <stddef.h>
#include <stdint.h>

#include "pf_handles.h"

/* Buffer text for Scheme's `foreign-procedure`: a flat, handle-based veneer over pf_text.
 * Positions are characters (see pf_text.h). Functions returning int64_t use -1 for "none"
 * (nothing to undo, out of range) and -2 for an invalid handle; int results are 0 or -2. Main
 * thread only. Byte arguments may point into Scheme bytevectors: nothing here calls back into
 * Scheme, so they cannot move during the call. */

pf_handle pf_buf_new(const char *bytes, size_t len); /* 0 on failure */
int pf_buf_free(pf_handle buf);

int64_t pf_buf_chars(pf_handle buf);
int64_t pf_buf_bytes(pf_handle buf);
int64_t pf_buf_lines(pf_handle buf);

int pf_buf_insert(pf_handle buf, size_t pos, const char *bytes, size_t len);
int pf_buf_delete(pf_handle buf, size_t start, size_t end);

/* Byte length of characters [START, END), and a copy of up to CAP of those bytes into OUT. */
int64_t pf_buf_range_bytes(pf_handle buf, size_t start, size_t end);
int64_t pf_buf_copy(pf_handle buf, size_t start, size_t end, char *out, size_t cap);

/* Code point of the character at POS (U+FFFD for a raw byte), or -1 past the end. */
int64_t pf_buf_char_at(pf_handle buf, size_t pos);

int64_t pf_buf_line_start(pf_handle buf, size_t line);
int64_t pf_buf_line_of(pf_handle buf, size_t pos);
int64_t pf_buf_char_to_byte(pf_handle buf, size_t pos);
int64_t pf_buf_byte_to_char(pf_handle buf, size_t byte);

/* Markers are pf_marker handles scoped to their buffer; 0 on failure. */
uint32_t pf_buf_marker_new(pf_handle buf, size_t pos, int advances);
int pf_buf_marker_free(pf_handle buf, uint32_t marker);
int64_t pf_buf_marker_pos(pf_handle buf, uint32_t marker); /* -1 for a stale marker */
int pf_buf_marker_set(pf_handle buf, uint32_t marker, size_t pos); /* -1 for a stale marker */

int pf_buf_undo_boundary(pf_handle buf);
int64_t pf_buf_undo(pf_handle buf); /* where point belongs, or -1 if nothing to undo */
int64_t pf_buf_redo(pf_handle buf);
int pf_buf_modified(pf_handle buf); /* 1, 0, or -2 */
int pf_buf_mark_saved(pf_handle buf);

#endif
