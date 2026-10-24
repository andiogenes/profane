#include "pf_git_ffi.h"

#include <stdlib.h>
#include <string.h>

#include "pf_git.h"
#include "pf_text.h"

int64_t pf_git_buffer_marks(pf_handle buf, const char *path, size_t len, uint32_t *out, size_t cap) {
    pf_text *t = pf_handle_get(buf, PF_HANDLE_TEXT);
    if (!t) {
        return -2;
    }
    const pf_text_snapshot *s = pf_text_current(t);
    size_t nbytes = pf_text_copy(s, 0, pf_text_chars(s), NULL, 0);
    char *bytes = malloc(nbytes + 1), *p = malloc(len + 1);
    pf_git_mark *marks = malloc((cap + 1) * sizeof *marks);
    if (!bytes || !p || !marks) {
        free(bytes), free(p), free(marks);
        return -2;
    }
    pf_text_copy(s, 0, pf_text_chars(s), bytes, nbytes);
    memcpy(p, path, len);
    p[len] = 0;
    long n = pf_git_line_marks(p, bytes, nbytes, marks, cap);
    for (long i = 0; i < n && (size_t)i < cap; i++) {
        out[3 * i] = marks[i].line;
        out[3 * i + 1] = marks[i].count;
        out[3 * i + 2] = marks[i].kind;
    }
    free(bytes), free(p), free(marks);
    return n;
}
