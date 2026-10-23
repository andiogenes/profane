#ifndef PF_UTF8_H
#define PF_UTF8_H

#include <stddef.h>

/* Length of the longest prefix of S[0..N) that does not end inside a multi-byte UTF-8 sequence.
 * Bytes past the returned length are the start of a sequence that may complete in a later chunk.
 * Invalid bytes are not rejected here; decoders downstream substitute U+FFFD. */
size_t pf_utf8_complete_prefix(const unsigned char *s, size_t n);

#endif
