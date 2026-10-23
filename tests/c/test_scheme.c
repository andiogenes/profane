/* Boots embedded Chez the way the app does (boot files + scheme/boot.ss) and drives the FFI
 * entry points. Needs no window or GPU. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_repl.h"
#include "pf_scheme.h"
#include "pf_test.h"

static char *call_text(const char *proc, const pf_scheme_arg *args, size_t nargs, int *status) {
    pf_scheme_result r;
    *status = pf_scheme_call(proc, args, nargs, &r);
    return r.text; /* caller frees */
}

static void check_repl(int64_t id, const char *input, const char *expected) {
    pf_scheme_arg args[] = {PF_SCHEME_INT(id), PF_SCHEME_STRING(input, strlen(input))};
    int status;
    char *out = call_text("pf-repl-input", args, 2, &status);
    PF_CHECK(status == 0);
    PF_CHECK_EQ_STR(out ? out : "", expected);
    free(out);
}

int main(void) {
    pf_scheme_options opts = {.boot_dir = PF_TEST_BOOT_DIR, .scheme_dir = PF_TEST_SCHEME_DIR};
    pf_scheme_options missing = {.boot_dir = "/nonexistent", .scheme_dir = PF_TEST_SCHEME_DIR};
    PF_CHECK(pf_scheme_init(&missing) == -1);
    if (pf_scheme_init(&opts) != 0) {
        fprintf(stderr, "cannot boot Chez from %s\n", PF_TEST_BOOT_DIR);
        return 1;
    }

    int status;
    char *hello = call_text("pf-hello-text", NULL, 0, &status);
    PF_CHECK(status == 0);
    PF_CHECK(hello && strncmp(hello, "Hello, profane — Chez Scheme Version 10.", 41) == 0);
    free(hello);

    /* A raising entry point reports and returns -1 instead of killing the process. */
    char *none = call_text("pf-quit", NULL, 0, &status);
    PF_CHECK(status == -1 && none == NULL);
    PF_CHECK(pf_scheme_call("no-such-procedure", NULL, 0, NULL) == -1);

    /* Non-string results succeed without text. */
    pf_scheme_arg id = PF_SCHEME_INT(1);
    PF_CHECK(pf_scheme_call("pf-repl-open", &id, 1, NULL) == 0);
    check_repl(1, "(+ 1 2)\n", "3\n");
    check_repl(1, "(define (sq x)\n", "");
    check_repl(1, "  (* x x))\n(sq 12)\n", "144\n");
    check_repl(1, "\"caf\xC3\xA9\"\n", "\"caf\xC3\xA9\"\n");
    check_repl(1, "(car 1)\n", "Exception in car: 1 is not a pair\n");
    check_repl(1, "(display \"hi\") 42", "hi");

    pf_scheme_result r;
    PF_CHECK(pf_scheme_call("pf-repl-close", &id, 1, &r) == 0);
    PF_CHECK_EQ_STR(r.text ? r.text : "", "42\n");
    pf_scheme_result_free(&r);

    /* Live redefinition: C looks entry points up by symbol on every call. */
    PF_CHECK(pf_scheme_call("pf-repl-open", &id, 1, NULL) == 0);
    check_repl(1, "(define (pf-hello-text) \"redefined\")\n", "");
    hello = call_text("pf-hello-text", NULL, 0, &status);
    PF_CHECK_EQ_STR(hello, "redefined");
    free(hello);

    /* Collection requests are deferred until idle. */
    check_repl(1, "(define c0 (collections))\n(define junk #f)\n", "");
    check_repl(1,
               "(let loop ([i 0]) (when (< i 200000) (set! junk (make-vector 100)) (loop (+ i 1))))\n",
               "");
    check_repl(1, "(list (= c0 (collections)) pf-collect-pending)\n", "(#t #t)\n");
    pf_scheme_idle();
    check_repl(1, "(list (> (collections) c0) pf-collect-pending)\n", "(#t #f)\n");
    free(call_text("pf-repl-close", &id, 1, &status));

    pf_scheme_deinit();
    return PF_TEST_RESULT();
}
