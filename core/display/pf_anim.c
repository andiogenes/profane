#include "pf_anim.h"

#include <math.h>

void pf_spring_step(pf_spring *s, float omega, float dt) {
    if (dt <= 0) {
        return;
    }
    float c1 = s->value - s->target, c2 = s->velocity + omega * c1;
    float e = expf(-omega * dt);
    s->value = s->target + (c1 + c2 * dt) * e;
    s->velocity = (c2 - omega * (c1 + c2 * dt)) * e;
}

void pf_spring_snap(pf_spring *s, float value) {
    s->value = s->target = value;
    s->velocity = 0;
}

int pf_spring_settled(const pf_spring *s, float eps) {
    return fabsf(s->value - s->target) <= eps && fabsf(s->velocity) <= eps * 10;
}

/* Off until Scheme applies `ui-motion` at startup, so C tests see no animation unless they ask. */
static int level = PF_MOTION_OFF, reduced;

void pf_motion_set_level(int l) {
    level = l < PF_MOTION_OFF ? PF_MOTION_OFF : l > PF_MOTION_FULL ? PF_MOTION_FULL : l;
}

void pf_motion_set_reduced(int r) {
    reduced = r != 0;
}

static int cursor_on;

void pf_motion_set_cursor(int on) {
    cursor_on = on != 0;
}

int pf_motion_cursor(void) {
    return cursor_on && pf_motion_level() > PF_MOTION_OFF;
}

static int scroll_on;

void pf_motion_set_scroll(int on) {
    scroll_on = on != 0;
}

int pf_motion_scroll(void) {
    return scroll_on && pf_motion_level() > PF_MOTION_OFF;
}

int pf_motion_level(void) {
    return reduced ? PF_MOTION_OFF : level;
}
