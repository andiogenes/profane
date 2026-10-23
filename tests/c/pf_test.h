#ifndef PF_TEST_H
#define PF_TEST_H

/* Minimal assertion helpers for C unit tests: each test binary returns nonzero on failure. */

#include <stdio.h>
#include <string.h>

static int pf_test_failures;

#define PF_CHECK(cond)                                                                             \
    do {                                                                                           \
        if (!(cond)) {                                                                             \
            fprintf(stderr, "%s:%d: check failed: %s\n", __FILE__, __LINE__, #cond);             \
            pf_test_failures++;                                                                    \
        }                                                                                          \
    } while (0)

#define PF_CHECK_EQ_SIZE(actual, expected)                                                         \
    do {                                                                                           \
        size_t a_ = (actual), e_ = (expected);                                                     \
        if (a_ != e_) {                                                                            \
            fprintf(stderr, "%s:%d: %s == %zu, expected %zu\n", __FILE__, __LINE__, #actual, a_,   \
                    e_);                                                                           \
            pf_test_failures++;                                                                    \
        }                                                                                          \
    } while (0)

#define PF_CHECK_EQ_STR(actual, expected)                                                          \
    do {                                                                                           \
        const char *a_ = (actual), *e_ = (expected);                                               \
        if (!a_ || strcmp(a_, e_) != 0) {                                                          \
            fprintf(stderr, "%s:%d: %s == \"%s\", expected \"%s\"\n", __FILE__, __LINE__, #actual, \
                    a_ ? a_ : "(null)", e_);                                                       \
            pf_test_failures++;                                                                    \
        }                                                                                          \
    } while (0)

#define PF_TEST_RESULT() (pf_test_failures == 0 ? 0 : 1)

#endif
