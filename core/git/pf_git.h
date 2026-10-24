#ifndef PF_GIT_H
#define PF_GIT_H

#include <stddef.h>
#include <stdint.h>

/* Git reads through libgit2 (mutations and the network go through the git CLI). Main thread
 * today; the calls are self-contained so a worker can take them over. Portable: no Chez. */

typedef enum pf_git_mark_kind {
    PF_GIT_ADDED = 1,    /* lines the buffer has and the index does not */
    PF_GIT_MODIFIED = 2, /* lines that differ from the index */
    PF_GIT_DELETED = 3,  /* lines removed just above LINE (count is 0) */
} pf_git_mark_kind;

typedef struct pf_git_mark {
    uint32_t line;  /* first line, 0-based */
    uint32_t count; /* lines; 0 for a deletion */
    uint32_t kind;  /* pf_git_mark_kind */
} pf_git_mark;

/* Compares BUF[0..LEN) (the contents of the file PATH, as edited) with the file's version in the
 * index, hunk by hunk. Writes up to CAP marks to OUT in line order and returns how many there
 * are (more than CAP: the rest were dropped), or -1 if PATH is not a file tracked by a
 * repository. */
long pf_git_line_marks(const char *path, const char *buf, size_t len, pf_git_mark *out, size_t cap);

#endif
