#ifndef PF_ANIM_H
#define PF_ANIM_H

/* The animation system's pieces (plan §6.5): critically damped springs, and the global motion
 * level. Time is passed in, so tests need no clock. Main thread only; portable. */

typedef struct pf_spring {
    float value, velocity, target;
} pf_spring;

/* Advances S by DT seconds toward its target. Critically damped (no overshoot) in closed form,
 * so any DT, even a long one, is stable. OMEGA is the stiffness in 1/s: about 4.6/OMEGA seconds
 * to settle within 1%. */
void pf_spring_step(pf_spring *s, float omega, float dt);
/* Puts S at VALUE at rest, with target VALUE. */
void pf_spring_snap(pf_spring *s, float value);
/* Within EPS of the target and nearly at rest. */
int pf_spring_settled(const pf_spring *s, float eps);

/* How much the interface animates: PF_MOTION_OFF, SUBTLE (smooth cursor and scroll), FULL (also
 * splits, resizes, pop-ups). Off by default in C; set from the `ui-motion` variable; macOS "Reduce Motion" overrides
 * it to off. */
enum { PF_MOTION_OFF = 0, PF_MOTION_SUBTLE = 1, PF_MOTION_FULL = 2 };
void pf_motion_set_level(int level);
void pf_motion_set_reduced(int reduced);
/* Per-feature switches, for what the level allows: the animated cursor (pf_window_tick). Off by
 * default; Scheme's `animate-cursor` sets it. */
void pf_motion_set_cursor(int on);
int pf_motion_cursor(void); /* on, and the level is not off */

/* The level in effect: OFF while Reduce Motion is on. */
int pf_motion_level(void);

#endif
