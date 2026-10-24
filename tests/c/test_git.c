#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "pf_git.h"
#include "pf_test.h"

static void write_file(const char *path, const char *text) {
    FILE *f = fopen(path, "w");
    fputs(text, f);
    fclose(f);
}

int main(void) {
    char dir[] = "/tmp/pf-git-XXXXXX";
    if (!mkdtemp(dir)) {
        return 1;
    }
    char cmd[512], file[300], other[300];
    snprintf(file, sizeof file, "%s/a.txt", dir);
    snprintf(other, sizeof other, "%s/untracked.txt", dir);
    write_file(file, "1\n2\n3\n4\n5\n6\n");
    write_file(other, "x\n");
    snprintf(cmd, sizeof cmd,
             "cd %s && git init -q && git add a.txt && "
             "git -c user.email=t@t -c user.name=t commit -q -m init",
             dir);
    PF_CHECK(system(cmd) == 0);

    pf_git_mark m[8];
    const char *same = "1\n2\n3\n4\n5\n6\n";
    PF_CHECK_EQ_INT(pf_git_line_marks(file, same, strlen(same), m, 8), 0);

    /* One added line (after 2), one modified (4), one deleted (6 removed: marked at the end). */
    const char *edited = "1\n2\nnew\n3\nFOUR\n5\n";
    long n = pf_git_line_marks(file, edited, strlen(edited), m, 8);
    PF_CHECK_EQ_INT(n, 3);
    PF_CHECK(m[0].kind == PF_GIT_ADDED && m[0].line == 2 && m[0].count == 1);
    PF_CHECK(m[1].kind == PF_GIT_MODIFIED && m[1].line == 4 && m[1].count == 1);
    PF_CHECK(m[2].kind == PF_GIT_DELETED && m[2].line == 6 && m[2].count == 0);

    /* Removing the first line is marked at the top. */
    const char *nofirst = "2\n3\n4\n5\n6\n";
    n = pf_git_line_marks(file, nofirst, strlen(nofirst), m, 8);
    PF_CHECK_EQ_INT(n, 1);
    PF_CHECK(m[0].kind == PF_GIT_DELETED && m[0].line == 0);

    /* More marks than room: the count is still returned. */
    n = pf_git_line_marks(file, edited, strlen(edited), m, 1);
    PF_CHECK_EQ_INT(n, 3);

    /* Untracked files and paths outside a repository have no marks. */
    PF_CHECK_EQ_INT(pf_git_line_marks(other, "x\n", 2, m, 8), -1);
    PF_CHECK_EQ_INT(pf_git_line_marks("/nonexistent/file", "x", 1, m, 8), -1);
    PF_CHECK_EQ_INT(pf_git_line_marks("/etc/hosts", "x", 1, m, 8), -1);

    snprintf(cmd, sizeof cmd, "rm -rf %s", dir);
    (void)!system(cmd);
    return PF_TEST_RESULT();
}
