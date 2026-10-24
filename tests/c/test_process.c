#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "pf_async.h"
#include "pf_process.h"
#include "pf_test.h"

typedef struct run {
    char out[1 << 20], err[1 << 10];
    size_t nout, nerr;
    int code, sig, exited;
} run;

/* Pumps events for TOKEN until the exit event (or 10 s), acknowledging output like Scheme does. */
static void collect(pf_handle h, uint64_t token, run *r) {
    memset(r, 0, sizeof *r);
    r->code = -2;
    for (int i = 0; i < 200 && !r->exited; i++) {
        pf_async_wait(50);
        uint64_t t;
        int kind;
        int64_t len;
        while ((len = pf_async_pop(&t, &kind)) >= 0) {
            unsigned char buf[65536];
            pf_async_data(buf, sizeof buf);
            PF_CHECK(t == token);
            if (kind == PF_PROC_EVENT_STDOUT) {
                if (r->nout + (size_t)len < sizeof r->out) {
                    memcpy(r->out + r->nout, buf, (size_t)len);
                }
                r->nout += (size_t)len;
                pf_proc_consumed(h, (size_t)len);
            } else if (kind == PF_PROC_EVENT_STDERR) {
                if (r->nerr + (size_t)len < sizeof r->err) {
                    memcpy(r->err + r->nerr, buf, (size_t)len);
                }
                r->nerr += (size_t)len;
                pf_proc_consumed(h, (size_t)len);
            } else if (kind == PF_PROC_EVENT_EXIT) {
                int32_t ev[2];
                memcpy(ev, buf, sizeof ev);
                r->code = ev[0];
                r->sig = ev[1];
                r->exited = 1;
            }
        }
    }
}

/* ARGV pieces as one NUL-terminated blob. */
static int64_t spawn(const char *blob, size_t len, const char *env, size_t env_len, const char *cwd,
                     int flags, uint64_t token) {
    return pf_proc_spawn(blob, len, env, env_len, cwd, cwd ? strlen(cwd) : 0, flags, token, 0, 0);
}

#define SH(script) "sh\0-c\0" script, sizeof("sh\0-c\0" script)

int main(void) {
    run *r = malloc(sizeof *r);

    /* stdout, stderr and the exit code arrive separately; stdout then stderr order is per stream */
    int64_t h = spawn(SH("echo hi; echo err 1>&2; exit 3"), NULL, 0, NULL, 0, 1);
    PF_CHECK(h > 0);
    PF_CHECK(pf_proc_pid((pf_handle)h) > 0);
    collect((pf_handle)h, 1, r);
    PF_CHECK(r->exited && r->code == 3 && r->sig == 0);
    PF_CHECK_EQ_STR(r->out, "hi\n");
    PF_CHECK_EQ_STR(r->err, "err\n");
    PF_CHECK(pf_proc_release((pf_handle)h) == 0);
    PF_CHECK(pf_proc_pid((pf_handle)h) == -1); /* the handle is dead */

    /* merged stderr */
    h = spawn(SH("echo a; echo b 1>&2"), NULL, 0, NULL, PF_PROC_MERGE_STDERR, 2);
    collect((pf_handle)h, 2, r);
    PF_CHECK(r->nerr == 0 && r->nout == 4);
    PF_CHECK(pf_proc_release((pf_handle)h) == 0);

    /* cwd and environment */
    h = spawn(SH("pwd; echo $PF_X"), "PF_X=seen", sizeof "PF_X=seen", "/", 0, 3);
    collect((pf_handle)h, 3, r);
    PF_CHECK_EQ_STR(r->out, "/\nseen\n");
    pf_proc_release((pf_handle)h);

    /* the environment is inherited, entries replaced or added */
    h = spawn(SH("echo $HOME $PF_Y"), "HOME=/x\0PF_Y=y", sizeof "HOME=/x\0PF_Y=y", NULL, 0, 3);
    collect((pf_handle)h, 3, r);
    PF_CHECK_EQ_STR(r->out, "/x y\n");
    pf_proc_release((pf_handle)h);
    h = spawn(SH("echo ${PATH:+path}"), NULL, 0, NULL, 0, 3);
    collect((pf_handle)h, 3, r);
    PF_CHECK_EQ_STR(r->out, "path\n");
    pf_proc_release((pf_handle)h);

    /* a program that cannot run is an error at spawn, not an exit */
    PF_CHECK(spawn("no-such-program-pf\0", 19, NULL, 0, NULL, 0, 4) == -2); /* -ENOENT */
    PF_CHECK(spawn(SH("true"), NULL, 0, "/no/such/dir", 0, 4) == -2);

    /* stdin: write, then EOF */
    h = spawn("cat\0", 4, NULL, 0, NULL, 0, 5);
    PF_CHECK(pf_proc_write((pf_handle)h, "ping\n", 5) == 0);
    PF_CHECK(pf_proc_eof((pf_handle)h) == 0);
    collect((pf_handle)h, 5, r);
    PF_CHECK_EQ_STR(r->out, "ping\n");
    PF_CHECK(r->code == 0);
    PF_CHECK(pf_proc_write((pf_handle)h, "x", 1) == -1); /* stdin is closed */
    pf_proc_release((pf_handle)h);

    /* a large write to a slow reader does not block the caller; a large read is backpressured */
    h = spawn(SH("head -c 3000000 /dev/zero | tr '\\0' x | wc -c"), NULL, 0, NULL, 0, 6);
    collect((pf_handle)h, 6, r);
    PF_CHECK(atoi(r->out) == 3000000);
    pf_proc_release((pf_handle)h);

    h = spawn("cat\0", 4, NULL, 0, NULL, 0, 7);
    char *big = malloc(2 << 20);
    memset(big, 'y', 2 << 20);
    PF_CHECK(pf_proc_write((pf_handle)h, big, 2 << 20) == 0);
    PF_CHECK(pf_proc_eof((pf_handle)h) == 0);
    collect((pf_handle)h, 7, r);
    PF_CHECK(r->exited && r->nout == (size_t)2 << 20);
    free(big);
    pf_proc_release((pf_handle)h);

    /* signals reach the group; the exit event says which */
    h = spawn(SH("sleep 30"), NULL, 0, NULL, 0, 8);
    usleep(100000);
    PF_CHECK(pf_proc_release((pf_handle)h) == -1); /* still running */
    PF_CHECK(pf_proc_signal((pf_handle)h, SIGTERM) == 0);
    collect((pf_handle)h, 8, r);
    PF_CHECK(r->exited && r->code == -1 && r->sig == SIGTERM);
    PF_CHECK(pf_proc_signal((pf_handle)h, SIGTERM) == -1); /* reaped: nothing to signal */
    pf_proc_release((pf_handle)h);

    /* a child's grandchild holding the pipe open does not hold back the exit */
    h = spawn(SH("sleep 3 & echo started"), NULL, 0, NULL, 0, 9);
    collect((pf_handle)h, 9, r);
    PF_CHECK(r->exited && r->code == 0);
    PF_CHECK_EQ_STR(r->out, "started\n");
    pf_proc_release((pf_handle)h);

    /* pty: a terminal, sized, echoing what is typed */
    h = pf_proc_spawn(SH("test -t 0 && echo tty; stty size; read x; echo got:$x"), NULL, 0, NULL, 0,
                      PF_PROC_PTY, 10, 10, 40);
    PF_CHECK(h > 0);
    PF_CHECK(pf_proc_write((pf_handle)h, "abc\n", 4) == 0);
    collect((pf_handle)h, 10, r);
    PF_CHECK(r->exited && r->code == 0);
    PF_CHECK(strstr(r->out, "tty\r\n") != NULL);
    PF_CHECK(strstr(r->out, "10 40\r\n") != NULL);
    PF_CHECK(strstr(r->out, "got:abc") != NULL);
    pf_proc_release((pf_handle)h);

    free(r);
    return pf_test_failures ? 1 : 0;
}
