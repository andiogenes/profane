#ifndef PF_ASYNC_H
#define PF_ASYNC_H

#include <stddef.h>
#include <stdint.h>

/* Completions from other threads, delivered to the main thread (plan §1, "Workers"). Any thread
 * posts an event (a token naming who waits for it, a kind, and a copy of some bytes); the main
 * thread pops them and Scheme resumes whatever waits on the token. Events from one thread arrive
 * in the order it posted them. The queue is unbounded: producers that can outrun the editor
 * must pace themselves (a process reader stops reading while its events are unpopped). */

/* Callable from any thread. DATA (LEN bytes) is copied. Returns 0, or -1 if out of memory. */
int pf_async_post(uint64_t token, int kind, const void *data, size_t len);

/* Posts one event (KIND, DATA) for TOKEN after MS milliseconds, from a detached thread: a timer
 * that costs a thread while it waits, fine for a few at a time. Returns 0, or -1 if no thread
 * could be started. */
int pf_async_post_after(uint64_t token, int kind, const void *data, size_t len, unsigned ms);

/* The shell sets WAKE (once, at startup) to be told, from the posting thread, that events are
 * waiting; it should arrange for the main thread to drain the queue. Calls are coalesced: one
 * wake until pf_async_wake_ack. With no hook set, nothing is called (tests poll). */
void pf_async_set_wake(void (*wake)(void));

/* Main thread, first thing in a drain: allows the next post to wake the shell again. */
void pf_async_wake_ack(void);

/* Main thread: asks for another wake now (a drain stopped early with events left). */
void pf_async_rewake(void);

/* Main thread: takes the oldest event. Returns its data length (>= 0) and sets *TOKEN and
 * *KIND, or returns -1 if none is waiting. The data stays held until pf_async_data copies it
 * out, which releases it; popping again first drops it. */
int64_t pf_async_pop(uint64_t *token, int *kind);
/* Copies up to CAP bytes of the held event's data into BUF and releases the event. */
void pf_async_data(void *buf, size_t cap);

/* Main thread: waits up to MS milliseconds for an event to be posted. Returns the number of
 * events waiting (0 on timeout). For tests and headless runs; the app is woken instead. */
int64_t pf_async_wait(unsigned ms);

/* Events waiting (not counting a held one). */
int64_t pf_async_pending(void);

#endif
