#include "pf_async.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

typedef struct event {
    struct event *next;
    uint64_t token;
    int kind;
    size_t len;
    unsigned char data[];
} event;

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t posted = PTHREAD_COND_INITIALIZER;
static event *head, *tail;
static int64_t count;
static int wake_pending;
static void (*wake_hook)(void);
static event *held; /* main thread only */

int pf_async_post(uint64_t token, int kind, const void *data, size_t len) {
    event *e = malloc(sizeof *e + len);
    if (!e) {
        return -1;
    }
    e->next = NULL;
    e->token = token;
    e->kind = kind;
    e->len = len;
    if (len) {
        memcpy(e->data, data, len);
    }
    pthread_mutex_lock(&lock);
    if (tail) {
        tail->next = e;
    } else {
        head = e;
    }
    tail = e;
    count++;
    int wake = !wake_pending && wake_hook;
    if (wake) {
        wake_pending = 1;
    }
    void (*hook)(void) = wake_hook;
    pthread_cond_broadcast(&posted);
    pthread_mutex_unlock(&lock);
    if (wake) {
        hook();
    }
    return 0;
}

typedef struct timer {
    uint64_t token;
    int kind;
    unsigned ms;
    size_t len;
    unsigned char data[];
} timer;

static void *timer_main(void *arg) {
    timer *t = arg;
    struct timespec ts = {.tv_sec = t->ms / 1000, .tv_nsec = (long)(t->ms % 1000) * 1000000L};
    while (nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
    pf_async_post(t->token, t->kind, t->data, t->len);
    free(t);
    return NULL;
}

int pf_async_post_after(uint64_t token, int kind, const void *data, size_t len, unsigned ms) {
    timer *t = malloc(sizeof *t + len);
    if (!t) {
        return -1;
    }
    t->token = token;
    t->kind = kind;
    t->ms = ms;
    t->len = len;
    if (len) {
        memcpy(t->data, data, len);
    }
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
    pthread_t thread;
    int rc = pthread_create(&thread, &attr, timer_main, t);
    pthread_attr_destroy(&attr);
    if (rc != 0) {
        free(t);
        return -1;
    }
    return 0;
}

void pf_async_set_wake(void (*wake)(void)) {
    pthread_mutex_lock(&lock);
    wake_hook = wake;
    pthread_mutex_unlock(&lock);
}

void pf_async_wake_ack(void) {
    pthread_mutex_lock(&lock);
    wake_pending = 0;
    pthread_mutex_unlock(&lock);
}

void pf_async_rewake(void) {
    pthread_mutex_lock(&lock);
    int wake = !wake_pending && wake_hook;
    if (wake) {
        wake_pending = 1;
    }
    void (*hook)(void) = wake_hook;
    pthread_mutex_unlock(&lock);
    if (wake) {
        hook();
    }
}

int64_t pf_async_pop(uint64_t *token, int *kind) {
    free(held);
    held = NULL;
    pthread_mutex_lock(&lock);
    event *e = head;
    if (e) {
        head = e->next;
        if (!head) {
            tail = NULL;
        }
        count--;
    }
    pthread_mutex_unlock(&lock);
    if (!e) {
        return -1;
    }
    held = e;
    *token = e->token;
    *kind = e->kind;
    return (int64_t)e->len;
}

void pf_async_data(void *buf, size_t cap) {
    if (!held) {
        return;
    }
    memcpy(buf, held->data, held->len < cap ? held->len : cap);
    free(held);
    held = NULL;
}

int64_t pf_async_wait(unsigned ms) {
    struct timespec until;
    clock_gettime(CLOCK_REALTIME, &until);
    until.tv_sec += ms / 1000;
    until.tv_nsec += (long)(ms % 1000) * 1000000L;
    if (until.tv_nsec >= 1000000000L) {
        until.tv_sec++;
        until.tv_nsec -= 1000000000L;
    }
    pthread_mutex_lock(&lock);
    while (count == 0) {
        if (pthread_cond_timedwait(&posted, &lock, &until) == ETIMEDOUT) {
            break;
        }
    }
    int64_t n = count;
    pthread_mutex_unlock(&lock);
    return n;
}

int64_t pf_async_pending(void) {
    pthread_mutex_lock(&lock);
    int64_t n = count;
    pthread_mutex_unlock(&lock);
    return n;
}
