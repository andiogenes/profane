/* Text properties: put/get/runs, merging, and movement with edits (directly and in pf_text). */

#include <string.h>

#include "pf_props.h"
#include "pf_test.h"
#include "pf_text.h"

static size_t runs(pf_props *p, uint32_t prop, pf_prop_run *out) {
    return pf_props_runs(p, prop, 0, 1000, out, 16);
}

#define CHECK_RUN(r, s, e, v) PF_CHECK((r).start == (s) && (r).end == (e) && (r).value == (v))

int main(void) {
    pf_props *p = pf_props_new();
    pf_prop_run r[16];

    PF_CHECK(pf_props_put(p, 0, 0, 1, 1) == -1);
    PF_CHECK(pf_props_put(p, PF_PROPS_MAX, 0, 1, 1) == -1);

    pf_props_put(p, 1, 10, 20, 7);
    PF_CHECK(pf_props_get(p, 1, 9) == 0 && pf_props_get(p, 1, 10) == 7);
    PF_CHECK(pf_props_get(p, 1, 19) == 7 && pf_props_get(p, 1, 20) == 0);
    PF_CHECK(pf_props_get(p, 2, 15) == 0); /* properties are independent */

    pf_props_put(p, 1, 20, 25, 7); /* touching, equal: merged */
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 1);
    CHECK_RUN(r[0], 10, 25, 7);

    pf_props_put(p, 1, 14, 16, 9); /* inside: splits into three */
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 3);
    CHECK_RUN(r[0], 10, 14, 7);
    CHECK_RUN(r[1], 14, 16, 9);
    CHECK_RUN(r[2], 16, 25, 7);

    pf_props_put(p, 1, 14, 16, 7); /* back to one run */
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 1);

    pf_props_put(p, 1, 12, 13, 0); /* removal punches a hole */
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 2);
    CHECK_RUN(r[0], 10, 12, 7);
    CHECK_RUN(r[1], 13, 25, 7);

    PF_CHECK_EQ_SIZE(pf_props_runs(p, 1, 11, 14, r, 16), 2); /* clipped to the query */
    CHECK_RUN(r[0], 11, 12, 7);
    CHECK_RUN(r[1], 13, 14, 7);

    /* Insertion: before a run shifts it; inside splits it (new text unpropertized); at a run's
     * end does not extend it. */
    pf_props_insert(p, 0, 5);
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 2);
    CHECK_RUN(r[0], 15, 17, 7);
    CHECK_RUN(r[1], 18, 30, 7);
    pf_props_insert(p, 20, 2);
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 3);
    CHECK_RUN(r[1], 18, 20, 7);
    CHECK_RUN(r[2], 22, 32, 7);
    PF_CHECK(pf_props_get(p, 1, 20) == 0 && pf_props_get(p, 1, 21) == 0);
    pf_props_insert(p, 32, 3);
    PF_CHECK(pf_props_get(p, 1, 32) == 0);

    /* Deletion: takes properties with it; runs that meet again merge. */
    pf_props_delete(p, 20, 22);
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 2);
    CHECK_RUN(r[1], 18, 30, 7);
    pf_props_delete(p, 16, 19); /* across a hole and into the next run */
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 1);
    CHECK_RUN(r[0], 15, 27, 7);
    pf_props_delete(p, 0, 100);
    PF_CHECK_EQ_SIZE(runs(p, 1, r), 0);
    pf_props_free(p);

    /* In pf_text: edits and undo move properties. */
    pf_text *t = pf_text_new("hello world", 11);
    pf_props *tp = pf_text_props(t);
    pf_props_put(tp, 1, 6, 11, 3); /* "world" */
    pf_text_insert(t, 0, ">> ", 3);
    PF_CHECK(pf_props_get(tp, 1, 8) == 0 && pf_props_get(tp, 1, 9) == 3);
    pf_text_undo_boundary(t);
    pf_text_delete(t, 0, 9);
    PF_CHECK(pf_props_get(tp, 1, 0) == 3);
    pf_text_undo(t, NULL);
    PF_CHECK(pf_props_get(tp, 1, 9) == 3); /* the surviving "world" moved back */
    pf_text_free(t);
    return PF_TEST_RESULT();
}
