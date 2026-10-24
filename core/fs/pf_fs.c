#include "pf_fs.h"

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

/* A NUL-terminated copy of a path on the stack or heap. */
static char *dup_path(const char *p, size_t len) {
    if (memchr(p, 0, len)) {
        return NULL;
    }
    char *s = malloc(len + 1);
    if (!s) {
        return NULL;
    }
    memcpy(s, p, len);
    s[len] = 0;
    return s;
}

int pf_fs_stat(const char *path, size_t len, int follow, int64_t *out) {
    char *p = dup_path(path, len);
    if (!p) {
        return -EINVAL;
    }
    struct stat st;
    int rc = follow ? stat(p, &st) : lstat(p, &st);
    int err = errno;
    free(p);
    if (rc != 0) {
        return -err;
    }
    out[PF_FS_MODE] = st.st_mode;
    out[PF_FS_SIZE] = st.st_size;
    out[PF_FS_MTIME] = st.st_mtime;
    out[PF_FS_UID] = st.st_uid;
    out[PF_FS_GID] = st.st_gid;
    out[PF_FS_NLINK] = st.st_nlink;
    return 0;
}

int64_t pf_fs_readlink(const char *path, size_t len, char *buf, size_t cap) {
    char *p = dup_path(path, len);
    if (!p) {
        return -EINVAL;
    }
    char tmp[PATH_MAX];
    ssize_t n = readlink(p, tmp, sizeof tmp);
    int err = errno;
    free(p);
    if (n < 0) {
        return -err;
    }
    memcpy(buf, tmp, (size_t)n < cap ? (size_t)n : cap);
    return n;
}

int64_t pf_fs_owner(int kind, uint32_t id, char *buf, size_t cap) {
    char scratch[4096];
    const char *name = NULL;
    if (kind == 0) {
        struct passwd pw, *res = NULL;
        if (getpwuid_r(id, &pw, scratch, sizeof scratch, &res) == 0 && res) {
            name = res->pw_name;
        }
    } else {
        struct group gr, *res = NULL;
        if (getgrgid_r(id, &gr, scratch, sizeof scratch, &res) == 0 && res) {
            name = res->gr_name;
        }
    }
    if (!name) {
        return -ENOENT;
    }
    size_t n = strlen(name);
    memcpy(buf, name, n < cap ? n : cap);
    return (int64_t)n;
}

int pf_fs_copy(const char *src, size_t slen, const char *dst, size_t dlen, int overwrite) {
    char *s = dup_path(src, slen);
    char *d = dup_path(dst, dlen);
    int result = 0;
    int in = -1, out = -1;
    if (!s || !d) {
        result = -EINVAL;
        goto done;
    }
    struct stat st;
    if (lstat(s, &st) != 0) {
        result = -errno;
        goto done;
    }
    if (S_ISDIR(st.st_mode)) {
        result = -EISDIR;
        goto done;
    }
    struct stat dst_st;
    int dst_exists = lstat(d, &dst_st) == 0;
    if (dst_exists && !overwrite) {
        result = -EEXIST;
        goto done;
    }
    if (dst_exists && st.st_ino == dst_st.st_ino && st.st_dev == dst_st.st_dev) {
        result = -EINVAL; /* the same file */
        goto done;
    }
    if (S_ISLNK(st.st_mode)) {
        char target[PATH_MAX];
        ssize_t n = readlink(s, target, sizeof target - 1);
        if (n < 0) {
            result = -errno;
            goto done;
        }
        target[n] = 0;
        if (dst_exists && unlink(d) != 0) {
            result = -errno;
            goto done;
        }
        if (symlink(target, d) != 0) {
            result = -errno;
        }
        goto done;
    }
    in = open(s, O_RDONLY);
    if (in < 0) {
        result = -errno;
        goto done;
    }
    /* Write beside the destination and rename over it, so a failed copy never leaves half a file
     * where a good one was. */
    char tmp_name[PATH_MAX];
    if ((size_t)snprintf(tmp_name, sizeof tmp_name, "%s.pfcopy.%d", d, (int)getpid()) >= sizeof tmp_name) {
        result = -ENAMETOOLONG;
        goto done;
    }
    out = open(tmp_name, O_WRONLY | O_CREAT | O_EXCL, st.st_mode & 07777);
    if (out < 0) {
        result = -errno;
        goto done;
    }
    char buf[65536];
    for (;;) {
        ssize_t n = read(in, buf, sizeof buf);
        if (n < 0 && errno == EINTR) {
            continue;
        }
        if (n < 0) {
            result = -errno;
            break;
        }
        if (n == 0) {
            break;
        }
        for (ssize_t off = 0; off < n;) {
            ssize_t w = write(out, buf + off, (size_t)(n - off));
            if (w < 0 && errno == EINTR) {
                continue;
            }
            if (w < 0) {
                result = -errno;
                goto failed;
            }
            off += w;
        }
    }
    if (result == 0) {
        fchmod(out, st.st_mode & 07777);
        struct timeval times[2] = {{st.st_atime, 0}, {st.st_mtime, 0}};
        futimes(out, times);
        if (close(out) != 0) {
            out = -1;
            result = -errno;
        } else {
            out = -1;
        }
    }
    if (result == 0 && rename(tmp_name, d) != 0) {
        result = -errno;
    }
failed:
    if (out >= 0) {
        close(out);
        out = -1;
    }
    if (result != 0) {
        unlink(tmp_name);
    }
done:
    if (in >= 0) {
        close(in);
    }
    free(s);
    free(d);
    return result;
}

int pf_fs_rename(const char *src, size_t slen, const char *dst, size_t dlen) {
    char *s = dup_path(src, slen);
    char *d = dup_path(dst, dlen);
    int rc = s && d ? (rename(s, d) == 0 ? 0 : -errno) : -EINVAL;
    free(s);
    free(d);
    return rc;
}

int pf_fs_mkdir(const char *path, size_t len, int mode) {
    char *p = dup_path(path, len);
    int rc = p ? (mkdir(p, (mode_t)mode) == 0 ? 0 : -errno) : -EINVAL;
    free(p);
    return rc;
}

int pf_fs_remove(const char *path, size_t len) {
    char *p = dup_path(path, len);
    int rc = -EINVAL;
    if (p) {
        struct stat st;
        if (lstat(p, &st) != 0) {
            rc = -errno;
        } else if (S_ISDIR(st.st_mode)) {
            rc = rmdir(p) == 0 ? 0 : -errno;
        } else {
            rc = unlink(p) == 0 ? 0 : -errno;
        }
    }
    free(p);
    return rc;
}
