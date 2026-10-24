#include <pthread.h>
#include <stdlib.h>

#include "pf_async.h"
#include "pf_test.h"

static int wakes;
static void wake(void) { __atomic_fetch_add(&wakes, 1, __ATOMIC_SEQ_CST); }

static void *producer(void *arg) {
    uint64_t id = (uint64_t)(uintptr_t)arg;
    for (int i = 0; i < 1000; i++) {
        int v = i;
        pf_async_post(id, 0, &v, sizeof v);
    }
    return NULL;
}

int main(void) {
    uint64_t token;
    int kind;

    PF_CHECK(pf_async_pop(&token, &kind) == -1);
    PF_CHECK(pf_async_post(5, 3, "abc", 3) == 0);
    PF_CHECK(pf_async_post(6, 4, NULL, 0) == 0);
    PF_CHECK_EQ_SIZE((size_t)pf_async_pending(), 2);
    PF_CHECK(pf_async_pop(&token, &kind) == 3);
    PF_CHECK(token == 5 && kind == 3);
    char buf[4] = {0};
    pf_async_data(buf, sizeof buf - 1);
    PF_CHECK_EQ_STR(buf, "abc");
    PF_CHECK(pf_async_pop(&token, &kind) == 0);
    PF_CHECK(token == 6 && kind == 4);
    PF_CHECK(pf_async_pop(&token, &kind) == -1); /* popping again drops the held empty event */

    /* wakes are coalesced until acknowledged */
    pf_async_set_wake(wake);
    pf_async_post(1, 0, NULL, 0);
    pf_async_post(1, 0, NULL, 0);
    PF_CHECK(wakes == 1);
    pf_async_wake_ack();
    pf_async_post(1, 0, NULL, 0);
    PF_CHECK(wakes == 2);
    pf_async_rewake(); /* already pending */
    PF_CHECK(wakes == 2);
    pf_async_wake_ack();
    pf_async_rewake();
    PF_CHECK(wakes == 3);
    while (pf_async_pop(&token, &kind) >= 0) {
    }
    pf_async_set_wake(NULL);

    /* the timer posts from another thread, after about its delay */
    PF_CHECK(pf_async_wait(5) == 0);
    PF_CHECK(pf_async_post_after(9, 2, "hi", 2, 30) == 0);
    PF_CHECK(pf_async_pending() == 0);
    PF_CHECK(pf_async_wait(5000) == 1);
    PF_CHECK(pf_async_pop(&token, &kind) == 2 && token == 9 && kind == 2);
    pf_async_data(buf, 2);
    PF_CHECK(buf[0] == 'h' && buf[1] == 'i');

    /* several producers: nothing lost, each producer's order kept */
    pthread_t threads[4];
    for (int i = 0; i < 4; i++) {
        pthread_create(&threads[i], NULL, producer, (void *)(uintptr_t)(100 + i));
    }
    for (int i = 0; i < 4; i++) {
        pthread_join(threads[i], NULL);
    }
    int next[4] = {0};
    int total = 0;
    while (pf_async_pop(&token, &kind) >= 0) {
        int v;
        pf_async_data(&v, sizeof v);
        int i = (int)token - 100;
        PF_CHECK(i >= 0 && i < 4 && v == next[i]);
        next[i]++;
        total++;
    }
    PF_CHECK(total == 4000);

    return pf_test_failures ? 1 : 0;
}
