#include "pf_input.h"

static int prefix_pending;

void pf_input_set_prefix_pending(int pending) {
    prefix_pending = pending != 0;
}

int pf_input_prefix_pending(void) {
    return prefix_pending;
}
