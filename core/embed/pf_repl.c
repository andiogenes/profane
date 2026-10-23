#include "pf_repl.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/un.h>

int pf_repl_socket_path(char *out, size_t size) {
    size_t max = sizeof(((struct sockaddr_un *)0)->sun_path);
    if (size < max) {
        max = size;
    }
    const char *env = getenv(PF_REPL_SOCKET_ENV);
    int n;
    if (env && *env) {
        n = snprintf(out, max, "%s", env);
    } else {
        const char *home = getenv("HOME");
        if (!home) {
            return -1;
        }
        n = snprintf(out, max, "%s/Library/Application Support/profane/repl.sock", home);
    }
    return n > 0 && (size_t)n < max ? 0 : -1;
}
