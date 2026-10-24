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

static int features[PF_MOTION_FEATURES];
static const int min_level[PF_MOTION_FEATURES] = {PF_MOTION_SUBTLE, PF_MOTION_SUBTLE,
                                                  PF_MOTION_FULL, PF_MOTION_FULL};

void pf_motion_set_feature(pf_motion_feature feature, int on) {
    if ((int)feature >= 0 && feature < PF_MOTION_FEATURES) {
        features[feature] = on != 0;
    }
}

int pf_motion_feature_on(pf_motion_feature feature) {
    return (int)feature >= 0 && feature < PF_MOTION_FEATURES && features[feature] &&
           pf_motion_level() >= min_level[feature];
}

void pf_motion_set_cursor(int on) {
    pf_motion_set_feature(PF_MOTION_CURSOR, on);
}

int pf_motion_cursor(void) {
    return pf_motion_feature_on(PF_MOTION_CURSOR);
}

void pf_motion_set_scroll(int on) {
    pf_motion_set_feature(PF_MOTION_SCROLL, on);
}

int pf_motion_scroll(void) {
    return pf_motion_feature_on(PF_MOTION_SCROLL);
}

int pf_motion_level(void) {
    return reduced ? PF_MOTION_OFF : level;
}
