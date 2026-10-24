#include "pf_process.h"

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#include "pf_async.h"

extern char **environ;

typedef struct pf_proc {
    pid_t pid;
    uint64_t token;
    int is_pty;
    int out_fd, err_fd, in_fd; /* -1 once closed; for a pty all three are the master */
    int wake_rd, wake_wr;      /* the main thread pokes the reader through this pipe */
    pthread_t thread;
    pthread_mutex_t mu; /* guards everything below, and the signalling of pid */
    unsigned char *obuf;
    size_t olen, ocap;
    int eof_requested;
    size_t outstanding;
    int reaped;
    int exited; /* the exit event has been posted */
} pf_proc;

static pthread_mutex_t live_mu = PTHREAD_MUTEX_INITIALIZER;
static pf_proc **live;
static size_t live_len, live_cap;
static int atexit_registered;

static void set_flags(int fd) {
    fcntl(fd, F_SETFD, fcntl(fd, F_GETFD) | FD_CLOEXEC);
}

static void set_nonblock(int fd) {
    fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK);
}

static void poke(pf_proc *p) {
    char c = 0;
    (void)!write(p->wake_wr, &c, 1);
}

static void post_exit(pf_proc *p, int status) {
    int32_t ev[2] = {-1, 0};
    if (WIFEXITED(status)) {
        ev[0] = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        ev[1] = WTERMSIG(status);
    }
    pf_async_post(p->token, PF_PROC_EVENT_EXIT, ev, sizeof ev);
}

/* Reads what is there, without blocking. Returns 0, or -1 at EOF or error (the fd is closed). */
static int read_some(pf_proc *p, int *fd, int kind, int ignore_limit) {
    unsigned char buf[16384];
    for (;;) {
        pthread_mutex_lock(&p->mu);
        int full = p->outstanding >= PF_PROC_MAX_OUTSTANDING;
        pthread_mutex_unlock(&p->mu);
        if (full && !ignore_limit) {
            return 0;
        }
        ssize_t n = read(*fd, buf, sizeof buf);
        if (n > 0) {
            pthread_mutex_lock(&p->mu);
            p->outstanding += (size_t)n;
            pthread_mutex_unlock(&p->mu);
            pf_async_post(p->token, kind, buf, (size_t)n);
            if (!ignore_limit) {
                return 0; /* back to poll: other descriptors get a turn */
            }
            continue;
        }
        if (n < 0 && (errno == EAGAIN || errno == EINTR)) {
            return 0;
        }
        /* EOF, or EIO: the other end of a pty is gone */
        if (p->is_pty) {
            pthread_mutex_lock(&p->mu);
            p->in_fd = p->err_fd = -1;
            pthread_mutex_unlock(&p->mu);
        }
        close(*fd);
        *fd = -1;
        return -1;
    }
}

static void flush_input(pf_proc *p) {
    pthread_mutex_lock(&p->mu);
    while (p->olen > 0 && p->in_fd >= 0) {
        ssize_t n = write(p->in_fd, p->obuf, p->olen);
        if (n > 0) {
            memmove(p->obuf, p->obuf + n, p->olen - (size_t)n);
            p->olen -= (size_t)n;
        } else if (n < 0 && errno == EINTR) {
            continue;
        } else if (n < 0 && errno == EAGAIN) {
            break;
        } else { /* EPIPE: the child closed its stdin; drop what is queued */
            p->olen = 0;
            break;
        }
    }
    if (p->olen == 0 && p->eof_requested && p->in_fd >= 0) {
        p->eof_requested = 0;
        if (p->is_pty) {
            char eof = 4;
            (void)!write(p->in_fd, &eof, 1);
        } else {
            close(p->in_fd);
            p->in_fd = -1;
        }
    }
    pthread_mutex_unlock(&p->mu);
}

/* Reaps the child if it has exited; returns 1 and its status then. */
static int try_reap(pf_proc *p, int block, int *status) {
    siginfo_t si;
    memset(&si, 0, sizeof si);
    if (waitid(P_PID, (id_t)p->pid, &si, WEXITED | WNOWAIT | (block ? 0 : WNOHANG)) != 0) {
        if (errno != ECHILD) {
            return 0;
        }
        *status = 0; /* reaped by someone else: nothing to learn */
        pthread_mutex_lock(&p->mu);
        p->reaped = 1;
        pthread_mutex_unlock(&p->mu);
        return 1;
    }
    if (si.si_pid == 0) {
        return 0;
    }
    pthread_mutex_lock(&p->mu); /* signalling holds it: no signal can reach a reaped pid */
    waitpid(p->pid, status, 0);
    p->reaped = 1;
    pthread_mutex_unlock(&p->mu);
    return 1;
}

static void *reader_main(void *arg) {
    pf_proc *p = arg;
    int status = 0;
    for (;;) {
        pthread_mutex_lock(&p->mu);
        int want_write = p->olen > 0 || p->eof_requested;
        int full = p->outstanding >= PF_PROC_MAX_OUTSTANDING;
        pthread_mutex_unlock(&p->mu);

        struct pollfd fds[4];
        int n = 0;
        fds[n++] = (struct pollfd){.fd = p->wake_rd, .events = POLLIN};
        int out_i = -1, err_i = -1, in_i = -1;
        if (p->out_fd >= 0) {
            out_i = n;
            fds[n++] = (struct pollfd){.fd = p->out_fd, .events = full ? 0 : POLLIN};
        }
        if (p->err_fd >= 0 && p->err_fd != p->out_fd) {
            err_i = n;
            fds[n++] = (struct pollfd){.fd = p->err_fd, .events = full ? 0 : POLLIN};
        }
        if (p->in_fd >= 0 && want_write) {
            in_i = n;
            fds[n++] = (struct pollfd){.fd = p->in_fd, .events = POLLOUT};
        }
        if (p->out_fd < 0 && p->err_fd < 0) {
            /* nothing left to read: wait for the child itself */
            if (try_reap(p, 1, &status)) {
                break;
            }
            continue;
        }
        int ready = poll(fds, (nfds_t)n, 50);
        if (ready > 0) {
            if (fds[0].revents & POLLIN) {
                char drain[64];
                while (read(p->wake_rd, drain, sizeof drain) > 0) {
                }
            }
            if (out_i >= 0 && fds[out_i].revents) {
                read_some(p, &p->out_fd, PF_PROC_EVENT_STDOUT, 0);
            }
            if (err_i >= 0 && fds[err_i].revents) {
                read_some(p, &p->err_fd, PF_PROC_EVENT_STDERR, 0);
            }
            if (in_i >= 0 && fds[in_i].revents) {
                flush_input(p);
            }
        }
        if (want_write && in_i < 0) {
            flush_input(p);
        }
        /* The child may have gone while a grandchild keeps the pipes open: it is done anyway. */
        if (try_reap(p, 0, &status)) {
            break;
        }
    }
    /* Whatever the child wrote before it went is still in the pipes. */
    if (p->out_fd >= 0) {
        while (read_some(p, &p->out_fd, PF_PROC_EVENT_STDOUT, 1) == 0 && p->out_fd >= 0) {
            struct pollfd pf = {.fd = p->out_fd, .events = POLLIN};
            if (poll(&pf, 1, 0) <= 0) {
                break;
            }
        }
    }
    if (p->err_fd >= 0 && p->err_fd != p->out_fd) {
        while (read_some(p, &p->err_fd, PF_PROC_EVENT_STDERR, 1) == 0 && p->err_fd >= 0) {
            struct pollfd pf = {.fd = p->err_fd, .events = POLLIN};
            if (poll(&pf, 1, 0) <= 0) {
                break;
            }
        }
    }
    pthread_mutex_lock(&p->mu);
    if (p->out_fd >= 0) {
        close(p->out_fd);
    }
    if (p->err_fd >= 0 && p->err_fd != p->out_fd) {
        close(p->err_fd);
    }
    if (p->in_fd >= 0 && p->in_fd != p->out_fd) {
        close(p->in_fd);
    }
    p->out_fd = p->err_fd = p->in_fd = -1;
    pthread_mutex_unlock(&p->mu);
    post_exit(p, status);
    pthread_mutex_lock(&p->mu);
    p->exited = 1;
    pthread_mutex_unlock(&p->mu);
    return NULL;
}

static char **split_strings(const char *blob, size_t len, size_t *count) {
    size_t n = 0;
    for (size_t i = 0; i < len; i++) {
        n += blob[i] == 0;
    }
    char **v = calloc(n + 1, sizeof *v);
    if (!v) {
        return NULL;
    }
    size_t k = 0;
    const char *s = blob;
    for (size_t i = 0; i < len; i++) {
        if (blob[i] == 0) {
            v[k++] = (char *)s;
            s = blob + i + 1;
        }
    }
    *count = n;
    return v;
}

/* The inherited environment with EXTRA (N "NAME=value" strings) replacing or adding entries. */
static char **merge_environment(char **extra, size_t n) {
    size_t have = 0;
    while (environ[have]) {
        have++;
    }
    char **v = calloc(have + n + 1, sizeof *v);
    if (!v) {
        return NULL;
    }
    memcpy(v, environ, have * sizeof *v);
    size_t len = have;
    for (size_t i = 0; i < n; i++) {
        const char *eq = strchr(extra[i], '=');
        size_t name = eq ? (size_t)(eq - extra[i]) + 1 : strlen(extra[i]);
        size_t k = 0;
        while (k < len && strncmp(v[k], extra[i], name) != 0) {
            k++;
        }
        v[k] = extra[i];
        if (k == len) {
            len++;
        }
    }
    return v;
}

static void forget(pf_proc *p) {
    pthread_mutex_lock(&live_mu);
    for (size_t i = 0; i < live_len; i++) {
        if (live[i] == p) {
            live[i] = live[--live_len];
            break;
        }
    }
    pthread_mutex_unlock(&live_mu);
}

static pthread_mutex_t spawn_mu = PTHREAD_MUTEX_INITIALIZER; /* ptsname is not thread-safe */

int64_t pf_proc_spawn(const char *argv_blob, size_t argv_len, const char *env_blob, size_t env_len,
                      const char *cwd_in, size_t cwd_len, int flags, uint64_t token, unsigned rows,
                      unsigned cols) {
    size_t argc = 0;
    char **argv = split_strings(argv_blob, argv_len, &argc);
    if (!argv || argc == 0 || (argv_len && argv_blob[argv_len - 1] != 0)) {
        free(argv);
        return -EINVAL;
    }
    char **envp = environ;
    char **owned_env = NULL;
    if (env_len) {
        size_t n;
        char **extra = split_strings(env_blob, env_len, &n);
        owned_env = extra ? merge_environment(extra, n) : NULL;
        free(extra);
        if (!owned_env) {
            free(argv);
            return -ENOMEM;
        }
        envp = owned_env;
    }
    char *cwd = NULL;
    if (cwd_len) {
        cwd = strndup(cwd_in, cwd_len);
    }
    int64_t result;
    pf_proc *p = calloc(1, sizeof *p);
    int err_pipe[2] = {-1, -1}, wake[2] = {-1, -1};
    int in_pipe[2] = {-1, -1}, out_pipe[2] = {-1, -1}, errout_pipe[2] = {-1, -1};
    int master = -1;
    char slave_name[256] = "";
    int is_pty = (flags & PF_PROC_PTY) != 0;
    struct winsize ws = {.ws_row = (unsigned short)(rows ? rows : 24),
                         .ws_col = (unsigned short)(cols ? cols : 80)};
    if (!p) {
        result = -ENOMEM;
        goto fail;
    }
    p->out_fd = p->err_fd = p->in_fd = -1;
    p->token = token;
    p->is_pty = is_pty;
    pthread_mutex_init(&p->mu, NULL);
    if (pipe(err_pipe) != 0 || pipe(wake) != 0) {
        result = -errno;
        goto fail;
    }
    set_flags(err_pipe[0]);
    set_flags(err_pipe[1]);
    set_flags(wake[0]);
    set_flags(wake[1]);
    set_nonblock(wake[0]);
    set_nonblock(wake[1]);
    if (is_pty) {
        pthread_mutex_lock(&spawn_mu);
        master = posix_openpt(O_RDWR | O_NOCTTY);
        if (master >= 0 && (grantpt(master) != 0 || unlockpt(master) != 0)) {
            close(master);
            master = -1;
        }
        const char *name = master >= 0 ? ptsname(master) : NULL;
        if (name) {
            strncpy(slave_name, name, sizeof slave_name - 1);
        }
        pthread_mutex_unlock(&spawn_mu);
        if (master < 0 || !*slave_name) {
            result = -EIO;
            goto fail;
        }
        set_flags(master);
    } else {
        if (pipe(in_pipe) != 0 || pipe(out_pipe) != 0 ||
            (!(flags & PF_PROC_MERGE_STDERR) && pipe(errout_pipe) != 0)) {
            result = -errno;
            goto fail;
        }
    }

    pid_t pid = fork();
    if (pid < 0) {
        result = -errno;
        goto fail;
    }
    if (pid == 0) {
        /* Child: only async-signal-safe calls from here to exec. */
        int fd_in, fd_out, fd_err;
        if (is_pty) {
            setsid();
            int slave = open(slave_name, O_RDWR);
            if (slave < 0) {
                goto child_fail;
            }
            ioctl(slave, TIOCSCTTY, 0);
            ioctl(slave, TIOCSWINSZ, &ws); /* set here: macOS drops a size set before the slave opens */
            fd_in = fd_out = fd_err = slave;
        } else {
            setpgid(0, 0);
            fd_in = in_pipe[0];
            fd_out = out_pipe[1];
            fd_err = (flags & PF_PROC_MERGE_STDERR) ? out_pipe[1] : errout_pipe[1];
        }
        dup2(fd_in, 0);
        dup2(fd_out, 1);
        dup2(fd_err, 2);
        int limit = (int)sysconf(_SC_OPEN_MAX);
        if (limit > 4096 || limit < 0) {
            limit = 4096;
        }
        for (int fd = 3; fd < limit; fd++) {
            if (fd != err_pipe[1]) {
                close(fd);
            }
        }
        sigset_t none;
        sigemptyset(&none);
        sigprocmask(SIG_SETMASK, &none, NULL);
        signal(SIGPIPE, SIG_DFL);
        if (cwd && chdir(cwd) != 0) {
            goto child_fail;
        }
        environ = envp;
        execvp(argv[0], argv);
    child_fail:;
        int e = errno;
        (void)!write(err_pipe[1], &e, sizeof e);
        _exit(127);
    }

    /* Parent. An exec failure comes back through err_pipe; a successful exec closes it. */
    close(err_pipe[1]);
    err_pipe[1] = -1;
    int child_errno = 0;
    ssize_t got;
    do {
        got = read(err_pipe[0], &child_errno, sizeof child_errno);
    } while (got < 0 && errno == EINTR);
    close(err_pipe[0]);
    err_pipe[0] = -1;
    if (got > 0) {
        waitpid(pid, NULL, 0);
        result = -(child_errno ? child_errno : ENOEXEC);
        goto fail;
    }
    p->pid = pid;
    if (is_pty) {
        p->out_fd = p->in_fd = p->err_fd = master;
        set_nonblock(master);
        master = -1;
    } else {
        close(in_pipe[0]);
        close(out_pipe[1]);
        p->in_fd = in_pipe[1];
        p->out_fd = out_pipe[0];
        in_pipe[0] = out_pipe[1] = -1;
        in_pipe[1] = out_pipe[0] = -1;
        set_flags(p->in_fd);
        set_flags(p->out_fd);
        set_nonblock(p->in_fd);
        set_nonblock(p->out_fd);
        if (errout_pipe[0] >= 0) {
            close(errout_pipe[1]);
            errout_pipe[1] = -1;
            p->err_fd = errout_pipe[0];
            errout_pipe[0] = -1;
            set_flags(p->err_fd);
            set_nonblock(p->err_fd);
        }
    }
    p->wake_rd = wake[0];
    p->wake_wr = wake[1];
    wake[0] = wake[1] = -1;

    pf_handle h = pf_handle_new(PF_HANDLE_PROCESS, p);
    if (!h) {
        kill(-pid, SIGKILL);
        waitpid(pid, NULL, 0);
        result = -ENOMEM;
        goto fail_after_fork;
    }
    pthread_mutex_lock(&live_mu);
    if (live_len == live_cap) {
        size_t cap = live_cap ? live_cap * 2 : 8;
        pf_proc **grown = realloc(live, cap * sizeof *live);
        if (grown) {
            live = grown;
            live_cap = cap;
        }
    }
    if (live_len < live_cap) {
        live[live_len++] = p;
    }
    if (!atexit_registered) {
        atexit_registered = 1;
        atexit(pf_proc_shutdown);
        signal(SIGPIPE, SIG_IGN); /* a write to a gone child is an error, not a signal */
    }
    pthread_mutex_unlock(&live_mu);
    if (pthread_create(&p->thread, NULL, reader_main, p) != 0) {
        forget(p);
        pf_handle_free(h, PF_HANDLE_PROCESS);
        kill(-pid, SIGKILL);
        waitpid(pid, NULL, 0);
        result = -EAGAIN;
        goto fail_after_fork;
    }
    free(argv);
    free(owned_env);
    free(cwd);
    return (int64_t)h;

fail_after_fork:
    if (p->out_fd >= 0) {
        close(p->out_fd);
    }
    if (p->err_fd >= 0 && p->err_fd != p->out_fd) {
        close(p->err_fd);
    }
    if (p->in_fd >= 0 && p->in_fd != p->out_fd) {
        close(p->in_fd);
    }
    close(p->wake_rd);
    close(p->wake_wr);
    p->wake_rd = p->wake_wr = -1;
fail:
    for (int i = 0; i < 2; i++) {
        int *fds[] = {err_pipe, wake, in_pipe, out_pipe, errout_pipe};
        for (size_t k = 0; k < sizeof fds / sizeof fds[0]; k++) {
            if (fds[k][i] >= 0) {
                close(fds[k][i]);
            }
        }
    }
    if (master >= 0) {
        close(master);
    }
    if (p) {
        pthread_mutex_destroy(&p->mu);
        free(p);
    }
    free(argv);
    free(owned_env);
    free(cwd);
    return result;
}

static pf_proc *get(pf_handle h) {
    return pf_handle_get(h, PF_HANDLE_PROCESS);
}

int64_t pf_proc_pid(pf_handle h) {
    pf_proc *p = get(h);
    return p ? (int64_t)p->pid : -1;
}

int pf_proc_write(pf_handle h, const void *bytes, size_t len) {
    pf_proc *p = get(h);
    if (!p) {
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    int ok = p->in_fd >= 0 && !p->eof_requested && !p->reaped;
    if (ok && len) {
        if (p->olen + len > p->ocap) {
            size_t cap = p->ocap ? p->ocap : 4096;
            while (cap < p->olen + len) {
                cap *= 2;
            }
            unsigned char *grown = realloc(p->obuf, cap);
            if (!grown) {
                ok = 0;
            } else {
                p->obuf = grown;
                p->ocap = cap;
            }
        }
        if (ok) {
            memcpy(p->obuf + p->olen, bytes, len);
            p->olen += len;
        }
    }
    pthread_mutex_unlock(&p->mu);
    if (ok) {
        poke(p);
    }
    return ok ? 0 : -1;
}

int pf_proc_eof(pf_handle h) {
    pf_proc *p = get(h);
    if (!p) {
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    int ok = p->in_fd >= 0 && !p->reaped;
    if (ok) {
        p->eof_requested = 1;
    }
    pthread_mutex_unlock(&p->mu);
    if (ok) {
        poke(p);
    }
    return ok ? 0 : -1;
}

int pf_proc_signal(pf_handle h, int sig) {
    pf_proc *p = get(h);
    if (!p) {
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    int rc = -1;
    if (!p->reaped) {
        rc = kill(-p->pid, sig);
        if (rc != 0) {
            rc = kill(p->pid, sig);
        }
    }
    pthread_mutex_unlock(&p->mu);
    return rc == 0 ? 0 : -1;
}

int pf_proc_resize(pf_handle h, unsigned rows, unsigned cols) {
    pf_proc *p = get(h);
    if (!p || !p->is_pty) {
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    int rc = -1;
    if (p->out_fd >= 0) {
        struct winsize ws = {.ws_row = (unsigned short)rows, .ws_col = (unsigned short)cols};
        rc = ioctl(p->out_fd, TIOCSWINSZ, &ws);
    }
    pthread_mutex_unlock(&p->mu);
    return rc == 0 ? 0 : -1;
}

int pf_proc_consumed(pf_handle h, size_t n) {
    pf_proc *p = get(h);
    if (!p) {
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    p->outstanding = n > p->outstanding ? 0 : p->outstanding - n;
    pthread_mutex_unlock(&p->mu);
    poke(p);
    return 0;
}

int pf_proc_release(pf_handle h) {
    pf_proc *p = get(h);
    if (!p) {
        return -1;
    }
    pthread_mutex_lock(&p->mu);
    int done = p->exited;
    pthread_mutex_unlock(&p->mu);
    if (!done) {
        return -1;
    }
    pthread_join(p->thread, NULL);
    forget(p);
    pf_handle_free(h, PF_HANDLE_PROCESS);
    close(p->wake_rd);
    close(p->wake_wr);
    pthread_mutex_destroy(&p->mu);
    free(p->obuf);
    free(p);
    return 0;
}

void pf_proc_shutdown(void) {
    pthread_mutex_lock(&live_mu);
    for (size_t i = 0; i < live_len; i++) {
        pf_proc *p = live[i];
        pthread_mutex_lock(&p->mu);
        if (!p->reaped) {
            kill(-p->pid, SIGHUP);
            kill(-p->pid, SIGCONT);
        }
        pthread_mutex_unlock(&p->mu);
    }
    pthread_mutex_unlock(&live_mu);
}
