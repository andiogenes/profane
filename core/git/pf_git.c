#include "pf_git.h"

#include <git2.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

typedef struct marks {
    pf_git_mark *out;
    size_t cap, n;
} marks;

static int hunk_cb(const git_diff_delta *delta, const git_diff_hunk *hunk, void *payload) {
    (void)delta;
    marks *m = payload;
    pf_git_mark mk;
    if (hunk->old_lines == 0) {
        mk = (pf_git_mark){(uint32_t)(hunk->new_start - 1), (uint32_t)hunk->new_lines, PF_GIT_ADDED};
    } else if (hunk->new_lines == 0) {
        /* With no context, new_start is the line before the removal (0: the top of the file). */
        mk = (pf_git_mark){(uint32_t)hunk->new_start, 0, PF_GIT_DELETED};
    } else {
        mk = (pf_git_mark){(uint32_t)(hunk->new_start - 1), (uint32_t)hunk->new_lines,
                           PF_GIT_MODIFIED};
    }
    if (m->n < m->cap) {
        m->out[m->n] = mk;
    }
    m->n++;
    return 0;
}

long pf_git_line_marks(const char *path, const char *buf, size_t len, pf_git_mark *out, size_t cap) {
    static int initialized;
    if (!initialized) {
        git_libgit2_init();
        initialized = 1;
    }
    char real[PATH_MAX];
    if (!realpath(path, real)) {
        return -1;
    }
    git_repository *repo = NULL;
    git_index *index = NULL;
    git_blob *blob = NULL;
    long result = -1;
    if (git_repository_open_ext(&repo, real, 0, NULL) != 0) {
        return -1;
    }
    const char *work = git_repository_workdir(repo);
    char *work_real = work ? realpath(work, NULL) : NULL;
    size_t wl = work_real ? strlen(work_real) : 0;
    if (!work_real || strncmp(real, work_real, wl) != 0) {
        goto done;
    }
    const char *rel = real + wl + (real[wl] == '/' ? 1 : 0);
    if (git_repository_index(&index, repo) != 0 || git_index_read(index, 0) != 0) {
        goto done;
    }
    const git_index_entry *entry = git_index_get_bypath(index, rel, 0);
    if (!entry || git_blob_lookup(&blob, repo, &entry->id) != 0) {
        goto done;
    }
    git_diff_options opts;
    git_diff_options_init(&opts, GIT_DIFF_OPTIONS_VERSION);
    opts.context_lines = 0;
    marks m = {out, cap, 0};
    if (git_diff_blob_to_buffer(blob, NULL, buf, len, NULL, &opts, NULL, NULL, hunk_cb, NULL, &m) ==
        0) {
        result = (long)m.n;
    }
done:
    free(work_real);
    git_blob_free(blob);
    git_index_free(index);
    git_repository_free(repo);
    return result;
}
