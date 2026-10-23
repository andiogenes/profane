#ifndef PF_SCHEME_H
#define PF_SCHEME_H

#include <stddef.h>
#include <stdint.h>

/* Embedded Chez Scheme. All functions must be called on the thread that called pf_scheme_init
 * (the main thread in the app). Scheme never sees C pointers; C never keeps Scheme objects. */

typedef struct pf_scheme_symbol {
    const char *name; /* visible to Scheme as (foreign-procedure "name" ...) */
    void *address;
} pf_scheme_symbol;

typedef struct pf_scheme_options {
    const char *boot_dir;   /* holds petite.boot and scheme.boot */
    const char *scheme_dir; /* holds boot.ss and the (profane ...) library tree */
    const pf_scheme_symbol *symbols;
    size_t symbol_count;
} pf_scheme_options;

/* Boots Chez and loads boot.ss. Returns 0 on success, -1 if a boot file or boot.ss is missing.
 * Errors inside boot.ss itself terminate the process (Chez has no handler installed yet). */
int pf_scheme_init(const pf_scheme_options *opts);
void pf_scheme_deinit(void);

typedef enum pf_scheme_arg_kind {
    PF_SCHEME_ARG_INT,
    PF_SCHEME_ARG_STRING,
} pf_scheme_arg_kind;

typedef struct pf_scheme_arg {
    pf_scheme_arg_kind kind;
    int64_t i;
    const char *s; /* UTF-8, not necessarily NUL-terminated */
    size_t len;
} pf_scheme_arg;

#define PF_SCHEME_INT(v) ((pf_scheme_arg){.kind = PF_SCHEME_ARG_INT, .i = (v)})
#define PF_SCHEME_STRING(p, n) ((pf_scheme_arg){.kind = PF_SCHEME_ARG_STRING, .s = (p), .len = (n)})

typedef struct pf_scheme_result {
    char *text; /* malloc'd, NUL-terminated UTF-8 when the procedure returned a string; else NULL */
    size_t len;
} pf_scheme_result;

/* Calls the top-level procedure PROC (looked up by name on every call, so it can be redefined
 * live) through the guarded `pf-ffi-call` trampoline. Returns 0 on success, -1 if the procedure
 * raised; the condition is reported on stderr. RESULT may be NULL. */
int pf_scheme_call(const char *proc, const pf_scheme_arg *args, size_t nargs,
                   pf_scheme_result *result);
void pf_scheme_result_free(pf_scheme_result *result);

/* Runs work deferred to idle time, currently garbage collection (see boot.ss). */
void pf_scheme_idle(void);

#endif
