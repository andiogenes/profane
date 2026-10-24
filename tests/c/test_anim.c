#include <math.h>

#include "pf_anim.h"
#include "pf_test.h"

int main(void) {
    /* A critically damped spring arrives without overshoot, and a long step is as good as many. */
    pf_spring s = {0, 0, 100};
    float prev = 0;
    for (int i = 0; i < 100; i++) {
        pf_spring_step(&s, 45, 0.01f);
        PF_CHECK(s.value >= prev - 1e-3f && s.value <= 100.0f + 1e-3f);
        prev = s.value;
    }
    PF_CHECK(pf_spring_settled(&s, 0.25f));

    pf_spring a = {0, 0, 100}, b = {0, 0, 100};
    for (int i = 0; i < 10; i++) {
        pf_spring_step(&a, 45, 0.01f);
    }
    pf_spring_step(&b, 45, 0.1f);
    PF_CHECK(fabsf(a.value - b.value) < 1e-2f && fabsf(a.velocity - b.velocity) < 1e-1f);

    /* Retargeting keeps the velocity: no jump. */
    pf_spring r = {0, 0, 100};
    pf_spring_step(&r, 45, 0.02f);
    float v = r.value;
    r.target = 0;
    PF_CHECK(r.value == v && r.velocity > 0);

    pf_spring_snap(&r, 7);
    PF_CHECK(r.value == 7 && r.target == 7 && r.velocity == 0 && pf_spring_settled(&r, 0.01f));
    pf_spring_step(&r, 45, 0);
    PF_CHECK(r.value == 7);

    /* The level: Reduce Motion wins and the setting is clamped. */
    PF_CHECK(pf_motion_level() == PF_MOTION_OFF);
    pf_motion_set_level(PF_MOTION_SUBTLE);
    PF_CHECK(pf_motion_level() == PF_MOTION_SUBTLE);
    pf_motion_set_level(PF_MOTION_FULL);
    PF_CHECK(pf_motion_level() == PF_MOTION_FULL);
    pf_motion_set_reduced(1);
    PF_CHECK(pf_motion_level() == PF_MOTION_OFF);
    pf_motion_set_reduced(0);
    pf_motion_set_level(99);
    PF_CHECK(pf_motion_level() == PF_MOTION_FULL);
    pf_motion_set_level(-3);
    PF_CHECK(pf_motion_level() == PF_MOTION_OFF);
    return PF_TEST_RESULT();
}
