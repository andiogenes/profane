#ifndef PF_FS_H
#define PF_FS_H

#include <stddef.h>
#include <stdint.h>

/* File system queries and copying for dired and friends (plan §8k). Paths are UTF-8 bytes with
 * a length (no NUL needed). Every function returns 0 or a byte count on success and -errno on
 * failure. */

enum {
    PF_FS_MODE,  /* st_mode: type and permission bits */
    PF_FS_SIZE,  /* bytes */
    PF_FS_MTIME, /* seconds since the epoch */
    PF_FS_UID,
    PF_FS_GID,
    PF_FS_NLINK,
    PF_FS_FIELDS,
};

/* Fills OUT[PF_FS_FIELDS] for PATH. FOLLOW 0 describes a symbolic link itself (lstat). */
int pf_fs_stat(const char *path, size_t len, int follow, int64_t *out);

/* The target of the symbolic link PATH, written to BUF (up to CAP bytes, no NUL); returns its
 * length, which may exceed CAP. */
int64_t pf_fs_readlink(const char *path, size_t len, char *buf, size_t cap);

/* The name of user (KIND 0) or group (KIND 1) ID, written to BUF; returns its length, or -ENOENT. */
int64_t pf_fs_owner(int kind, uint32_t id, char *buf, size_t cap);

/* Copies the regular file or symbolic link SRC to DST, keeping permissions and modification time
 * (a link is copied as a link). Fails with -EEXIST if DST exists and OVERWRITE is 0. Not for
 * directories (-EISDIR). */
int pf_fs_copy(const char *src, size_t slen, const char *dst, size_t dlen, int overwrite);

/* Renames SRC to DST (replacing a file; a directory only over an empty one). -EXDEV across file
 * systems: the caller copies and deletes. */
int pf_fs_rename(const char *src, size_t slen, const char *dst, size_t dlen);

/* Creates the directory PATH (one level) with permissions MODE minus the umask. */
int pf_fs_mkdir(const char *path, size_t len, int mode);

/* Removes the file, symbolic link (itself) or empty directory PATH. */
int pf_fs_remove(const char *path, size_t len);

#endif
