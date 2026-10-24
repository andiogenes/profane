#include "pf_input.h"

#include <stdlib.h>
#include <string.h>

static int prefix_pending;

void pf_input_set_prefix_pending(int pending) {
    prefix_pending = pending != 0;
}

int pf_input_prefix_pending(void) {
    return prefix_pending;
}

static int busy;

void pf_input_set_busy(int b) {
    busy = b != 0;
}

int pf_input_busy(void) {
    return busy;
}

static char *hold_keys; /* "\ne\na\n": every key wrapped in newlines, so a lookup is a substring */

void pf_input_set_press_and_hold(const char *keys, size_t len) {
    free(hold_keys);
    hold_keys = malloc(len + 3);
    if (!hold_keys) {
        return;
    }
    hold_keys[0] = '\n';
    memcpy(hold_keys + 1, keys, len);
    hold_keys[len + 1] = '\n';
    hold_keys[len + 2] = 0;
}

int pf_input_press_and_hold(const char *key) {
    if (!hold_keys || !key || !*key || strchr(key, '\n')) {
        return 0;
    }
    size_t n = strlen(key);
    char *needle = malloc(n + 3);
    if (!needle) {
        return 0;
    }
    needle[0] = '\n';
    memcpy(needle + 1, key, n);
    needle[n + 1] = '\n';
    needle[n + 2] = 0;
    int found = strstr(hold_keys, needle) != NULL;
    free(needle);
    return found;
}
