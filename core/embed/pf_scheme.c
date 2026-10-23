#include "pf_scheme.h"

#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "scheme.h"

#define PF_SCHEME_MAX_ARGS 8

static int initialized;
static pthread_t scheme_thread;

static int join_path(char *out, size_t size, const char *dir, const char *file) {
    int n = snprintf(out, size, "%s/%s", dir, file);
    return n > 0 && (size_t)n < size ? 0 : -1;
}

static int readable(const char *path) {
    if (access(path, R_OK) == 0) {
        return 1;
    }
    fprintf(stderr, "profane: cannot read %s\n", path);
    return 0;
}

int pf_scheme_init(const pf_scheme_options *opts) {
    char petite[4096], scheme[4096], boot_ss[4096];
    if (initialized || join_path(petite, sizeof petite, opts->boot_dir, "petite.boot") != 0 ||
        join_path(scheme, sizeof scheme, opts->boot_dir, "scheme.boot") != 0 ||
        join_path(boot_ss, sizeof boot_ss, opts->scheme_dir, "boot.ss") != 0) {
        return -1;
    }
    /* Chez exits the process on a missing boot file, so check first. */
    if (!readable(petite) || !readable(scheme) || !readable(boot_ss)) {
        return -1;
    }

    Sscheme_init(NULL);
    Sregister_boot_file(petite);
    Sregister_boot_file(scheme);
    Sbuild_heap(NULL, NULL);
    initialized = 1;
    scheme_thread = pthread_self();

    for (size_t i = 0; i < opts->symbol_count; i++) {
        Sforeign_symbol(opts->symbols[i].name, opts->symbols[i].address);
    }
    Sset_top_level_value(Sstring_to_symbol("pf-scheme-dir"), Sstring(opts->scheme_dir));
    Scall1(Stop_level_value(Sstring_to_symbol("load")), Sstring(boot_ss));
    return 0;
}

void pf_scheme_deinit(void) {
    if (initialized) {
        Sscheme_deinit();
        initialized = 0;
    }
}

int pf_scheme_call(const char *proc, const pf_scheme_arg *args, size_t nargs,
                   pf_scheme_result *result) {
    assert(initialized && pthread_equal(scheme_thread, pthread_self()));
    if (result) {
        result->text = NULL;
        result->len = 0;
    }
    if (nargs > PF_SCHEME_MAX_ARGS) {
        return -1;
    }

    /* Collections only run while Scheme code runs, so these objects stay put until Scall. */
    ptr argv[PF_SCHEME_MAX_ARGS + 1];
    argv[0] = Sstring_to_symbol(proc);
    for (size_t i = 0; i < nargs; i++) {
        argv[i + 1] = args[i].kind == PF_SCHEME_ARG_INT ? Sinteger64(args[i].i)
                                                        : Sstring_utf8(args[i].s, (iptr)args[i].len);
    }
    ptr trampoline = Stop_level_value(Sstring_to_symbol("pf-ffi-call"));
    Sinitframe((iptr)nargs + 1);
    for (size_t i = 0; i <= nargs; i++) {
        Sput_arg((iptr)i + 1, argv[i]);
    }
    ptr v = Scall(trampoline, (iptr)nargs + 1);

    /* pf-ffi-call returns #f on failure, a UTF-8 bytevector for a string result, else #t. */
    if (v == Sfalse) {
        return -1;
    }
    if (Sbytevectorp(v) && result) {
        size_t len = (size_t)Sbytevector_length(v);
        char *text = malloc(len + 1);
        if (!text) {
            return -1;
        }
        memcpy(text, Sbytevector_data(v), len); /* copy before anything else can allocate */
        text[len] = '\0';
        result->text = text;
        result->len = len;
    }
    return 0;
}

void pf_scheme_result_free(pf_scheme_result *result) {
    free(result->text);
    result->text = NULL;
    result->len = 0;
}

void pf_scheme_idle(void) {
    pf_scheme_call("pf-idle", NULL, 0, NULL);
}
