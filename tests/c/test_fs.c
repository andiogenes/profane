#include <errno.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>

#include "pf_fs.h"
#include "pf_test.h"

static void write_file(const char *path, const char *text, mode_t mode) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, mode);
    (void)!write(fd, text, strlen(text));
    close(fd);
    chmod(path, mode);
}

static char *read_file(const char *path, char *buf, size_t cap) {
    int fd = open(path, O_RDONLY);
    ssize_t n = fd < 0 ? -1 : read(fd, buf, cap - 1);
    buf[n < 0 ? 0 : n] = 0;
    if (fd >= 0) {
        close(fd);
    }
    return buf;
}

#define LEN(s) s, strlen(s)

int main(void) {
    char root[] = "/tmp/pf-fs-XXXXXX";
    PF_CHECK(mkdtemp(root) != NULL);
    char a[512], link[512], dir[512], b[512];
    snprintf(a, sizeof a, "%s/a.txt", root);
    snprintf(link, sizeof link, "%s/ln", root);
    snprintf(dir, sizeof dir, "%s/d", root);
    snprintf(b, sizeof b, "%s/b.txt", root);
    write_file(a, "hello", 0640);
    mkdir(dir, 0755);
    PF_CHECK(symlink("a.txt", link) == 0);

    int64_t st[PF_FS_FIELDS];
    PF_CHECK(pf_fs_stat(LEN(a), 0, st) == 0);
    PF_CHECK(S_ISREG(st[PF_FS_MODE]) && (st[PF_FS_MODE] & 0777) == 0640);
    PF_CHECK(st[PF_FS_SIZE] == 5 && st[PF_FS_UID] == (int64_t)getuid() && st[PF_FS_NLINK] == 1);
    PF_CHECK(st[PF_FS_MTIME] > 1600000000);
    PF_CHECK(pf_fs_stat(LEN(dir), 0, st) == 0 && S_ISDIR(st[PF_FS_MODE]));
    PF_CHECK(pf_fs_stat(LEN(link), 0, st) == 0 && S_ISLNK(st[PF_FS_MODE]));
    PF_CHECK(pf_fs_stat(LEN(link), 1, st) == 0 && S_ISREG(st[PF_FS_MODE]) && st[PF_FS_SIZE] == 5);
    PF_CHECK(pf_fs_stat(LEN("/tmp/pf-fs-no-such"), 0, st) == -ENOENT);
    PF_CHECK(pf_fs_stat("a\0b", 3, 0, st) == -EINVAL);

    char buf[64];
    PF_CHECK(pf_fs_readlink(LEN(link), buf, sizeof buf) == 5 && memcmp(buf, "a.txt", 5) == 0);
    PF_CHECK(pf_fs_readlink(LEN(a), buf, sizeof buf) == -EINVAL);

    PF_CHECK(pf_fs_owner(0, 0, buf, sizeof buf) == 4 && memcmp(buf, "root", 4) == 0);
    PF_CHECK(pf_fs_owner(1, (uint32_t)getgid(), buf, sizeof buf) > 0);
    PF_CHECK(pf_fs_owner(0, 987654, buf, sizeof buf) == -ENOENT);

    /* copy: contents, mode, mtime; refuses to overwrite unless told to */
    struct timeval old[2] = {{1000000000, 0}, {1000000000, 0}};
    utimes(a, old);
    PF_CHECK(pf_fs_copy(LEN(a), LEN(b), 0) == 0);
    char text[64];
    PF_CHECK_EQ_STR(read_file(b, text, sizeof text), "hello");
    PF_CHECK(pf_fs_stat(LEN(b), 0, st) == 0 && (st[PF_FS_MODE] & 0777) == 0640 &&
             st[PF_FS_MTIME] == 1000000000);
    PF_CHECK(pf_fs_copy(LEN(a), LEN(b), 0) == -EEXIST);
    write_file(a, "changed", 0640);
    PF_CHECK(pf_fs_copy(LEN(a), LEN(b), 1) == 0);
    PF_CHECK_EQ_STR(read_file(b, text, sizeof text), "changed");
    PF_CHECK(pf_fs_copy(LEN(a), LEN(a), 1) == -EINVAL);
    PF_CHECK(pf_fs_copy(LEN(dir), LEN(b), 1) == -EISDIR);
    PF_CHECK(pf_fs_copy(LEN("/tmp/pf-fs-no-such"), LEN(b), 1) == -ENOENT);
    char nodir[600];
    snprintf(nodir, sizeof nodir, "%s/nodir/x", root);
    PF_CHECK(pf_fs_copy(LEN(a), LEN(nodir), 1) == -ENOENT);
    PF_CHECK_EQ_STR(read_file(b, text, sizeof text), "changed"); /* a failed copy leaves nothing odd */

    /* a link is copied as a link */
    char link2[512];
    snprintf(link2, sizeof link2, "%s/ln2", root);
    PF_CHECK(pf_fs_copy(LEN(link), LEN(link2), 0) == 0);
    PF_CHECK(pf_fs_stat(LEN(link2), 0, st) == 0 && S_ISLNK(st[PF_FS_MODE]));
    PF_CHECK(pf_fs_readlink(LEN(link2), buf, sizeof buf) == 5);

    /* a large file */
    char big[512];
    snprintf(big, sizeof big, "%s/big", root);
    int fd = open(big, O_WRONLY | O_CREAT, 0644);
    char chunk[65536];
    memset(chunk, 'z', sizeof chunk);
    for (int i = 0; i < 40; i++) {
        (void)!write(fd, chunk, sizeof chunk);
    }
    close(fd);
    char big2[512];
    snprintf(big2, sizeof big2, "%s/big2", root);
    PF_CHECK(pf_fs_copy(LEN(big), LEN(big2), 0) == 0);
    PF_CHECK(pf_fs_stat(LEN(big2), 0, st) == 0 && st[PF_FS_SIZE] == 40 * 65536);

    /* rename, mkdir, remove */
    char moved[512], sub[512];
    snprintf(moved, sizeof moved, "%s/moved.txt", root);
    snprintf(sub, sizeof sub, "%s/newdir", root);
    PF_CHECK(pf_fs_rename(LEN(b), LEN(moved)) == 0 && access(b, F_OK) != 0 && access(moved, F_OK) == 0);
    PF_CHECK(pf_fs_rename(LEN(b), LEN(moved)) == -ENOENT);
    PF_CHECK(pf_fs_mkdir(LEN(sub), 0755) == 0);
    PF_CHECK(pf_fs_mkdir(LEN(sub), 0755) == -EEXIST);
    write_file(nodir, "x", 0644); /* fails: no such dir */
    char inner[600];
    snprintf(inner, sizeof inner, "%s/f", sub);
    write_file(inner, "x", 0644);
    PF_CHECK(pf_fs_remove(LEN(sub)) == -ENOTEMPTY);
    PF_CHECK(pf_fs_remove(LEN(inner)) == 0);
    PF_CHECK(pf_fs_remove(LEN(sub)) == 0 && access(sub, F_OK) != 0);
    PF_CHECK(pf_fs_remove(LEN(link)) == 0 && access(a, F_OK) == 0); /* the link, not its target */
    PF_CHECK(pf_fs_remove(LEN(sub)) == -ENOENT);

    char cmd[600];
    snprintf(cmd, sizeof cmd, "rm -rf %s", root);
    (void)!system(cmd);
    return pf_test_failures ? 1 : 0;
}
