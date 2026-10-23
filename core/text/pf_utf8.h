#ifndef PF_UTF8_H
#define PF_UTF8_H

#include <stddef.h>

/* Length of the longest prefix of S[0..N) that does not end inside a multi-byte UTF-8 sequence.
 * Bytes past the returned length are the start of a sequence that may complete in a later chunk.
 * Invalid bytes are not rejected here; decoders downstream substitute U+FFFD. */
size_t pf_utf8_complete_prefix(const unsigned char *s, size_t n);

/* A "unit" is what the text core counts as one character: a well-formed UTF-8 sequence
 * (RFC 3629: no overlongs, surrogates or code points above U+10FFFF) or, failing that, a single
 * byte. Every byte string splits into units, so positions stay well defined and text with
 * invalid bytes round-trips unchanged. */

/* Byte length (1-4) of the unit starting at S; N must be > 0. */
size_t pf_utf8_unit_len(const unsigned char *s, size_t n);

/* Number of units in S[0..N). */
size_t pf_utf8_count_units(const unsigned char *s, size_t n);

/* Byte offset of unit K in S[0..N) (N if K is past the end). */
size_t pf_utf8_unit_offset(const unsigned char *s, size_t n, size_t k);

#endif
