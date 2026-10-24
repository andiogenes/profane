#ifndef PF_PROCESS_H
#define PF_PROCESS_H

#include <stddef.h>
#include <stdint.h>

#include "pf_handles.h"

/* Child processes over pipes or a pseudo-terminal (plan §8k). Each process has a reader thread
 * that owns its descriptors: it reads output, writes what the main thread queued, notices the
 * exit and reaps the child. Results reach the main thread as pf_async events for the TOKEN given
 * at spawn (core/async/pf_async.h), in this order for one process:
 *   PF_PROC_EVENT_STDOUT / PF_PROC_EVENT_STDERR  the bytes read (stdout is the terminal for a pty)
 *   PF_PROC_EVENT_EXIT                           8 bytes: int32 exit code (-1 if killed), int32
 *                                                signal number (0 if it exited)
 * The exit event is the last: nothing follows it, and the process may then be released. All
 * functions below except the reader thread are main-thread only (they use pf_handles). */

enum {
    PF_PROC_EVENT_STDOUT = 1,
    PF_PROC_EVENT_STDERR = 2,
    PF_PROC_EVENT_EXIT = 3,
};

enum {
    PF_PROC_PTY = 1,          /* run on a pseudo-terminal (stdout and stderr are the terminal) */
    PF_PROC_MERGE_STDERR = 2, /* pipes only: stderr goes to the stdout pipe */
};

/* Output not yet acknowledged (pf_proc_consumed) above which the reader stops reading, so a
 * chatty child blocks in write() instead of filling the event queue. */
#define PF_PROC_MAX_OUTSTANDING (256 * 1024)

/* Starts ARGV (ARGC strings: NUL-terminated, one after another in ARGV; the first is the
 * program, searched in PATH) in directory CWD (empty: inherited). ENV is NUL-separated
 * "NAME=value" strings that replace or add entries of the inherited environment (empty: none). ROWS/COLS size a pty (0: 24x80).
 * Returns a handle, or -errno (a program that cannot be run is reported here, not as an exit). */
int64_t pf_proc_spawn(const char *argv, size_t argv_len, const char *env, size_t env_len,
                      const char *cwd, size_t cwd_len, int flags, uint64_t token, unsigned rows,
                      unsigned cols);

int64_t pf_proc_pid(pf_handle h);
/* Queues BYTES for the child's stdin and returns at once. -1 if the handle is invalid, stdin
 * was closed or the process is gone. */
int pf_proc_write(pf_handle h, const void *bytes, size_t len);
/* Closes the child's stdin once what is queued is written (a pty gets ^D instead). */
int pf_proc_eof(pf_handle h);
/* Sends SIG to the child's process group. -1 if the handle is invalid or the child was reaped. */
int pf_proc_signal(pf_handle h, int sig);
int pf_proc_resize(pf_handle h, unsigned rows, unsigned cols);
/* Acknowledges N bytes of output events handled, letting the reader read more. */
int pf_proc_consumed(pf_handle h, size_t n);
/* Frees a process after its exit event. -1 (and nothing freed) if it has not exited yet. */
int pf_proc_release(pf_handle h);
/* Hangs up every live child (called at exit; also registered with atexit). */
void pf_proc_shutdown(void);

#endif
