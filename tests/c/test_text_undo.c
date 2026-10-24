/* Markers and the undo tree. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "pf_test.h"
#include "pf_text.h"

static char *contents(const pf_text *t) {
    const pf_text_snapshot *s = pf_text_current(t);
    size_t len = pf_text_bytes(s);
    char *out = malloc(len + 1);
    pf_text_copy(s, 0, pf_text_chars(s), out, len);
    out[len] = '\0';
    return out;
}

#define CHECK_TEXT(t, expected)                                                                    \
    do {                                                                                           \
        char *got_ = contents(t);                                                                  \
        PF_CHECK_EQ_STR(got_, expected);                                                           \
        free(got_);                                                                                \
    } while (0)

static void insert(pf_text *t, size_t pos, const char *s) {
    PF_CHECK(pf_text_insert(t, pos, s, strlen(s)) == 0);
}

static void test_markers(void) {
    pf_text *t = pf_text_new("hello world", 11);
    pf_marker stay = pf_marker_new(t, 5, 0), adv = pf_marker_new(t, 5, 1);
    pf_marker end = pf_marker_new(t, 99, 0); /* clamped */
    PF_CHECK(stay && adv && end && stay != adv);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, end), 11);

    insert(t, 5, ",");          /* at the markers */
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), 5);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, adv), 6);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, end), 12);
    insert(t, 0, ">> ");         /* before all */
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), 8);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, adv), 9);

    pf_text_delete(t, 7, 10);    /* spans both markers: they collapse to the start */
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), 7);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, adv), 7);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, end), 12);

    PF_CHECK(pf_marker_set(t, stay, 1000) == 0);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), 12);

    /* Freed handles stay invalid even when the slot is reused. */
    pf_marker_free(t, stay);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), SIZE_MAX);
    PF_CHECK(pf_marker_set(t, stay, 0) == -1);
    pf_marker again = pf_marker_new(t, 0, 0);
    PF_CHECK(again != stay);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), SIZE_MAX);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, again), 0);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, 0), SIZE_MAX);
    pf_marker_free(t, 0); /* harmless */
    pf_text_free(t);
}

/* Regression: when typing extended the previous piece, the change was recorded at the position
 * after the extension, so markers and undo positions drifted by one keystroke. */
static void test_markers_while_typing(void) {
    pf_text *t = pf_text_new(NULL, 0);
    insert(t, 0, "a");
    pf_marker stay = pf_marker_new(t, 1, 0), adv = pf_marker_new(t, 1, 1);
    insert(t, 1, "b");
    insert(t, 2, "c"); /* extends the "ab" piece */
    insert(t, 3, "d");
    CHECK_TEXT(t, "abcd");
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, stay), 1);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, adv), 4);
    pf_text_free(t);
}

static void test_undo_groups(void) {
    pf_text *t = pf_text_new(NULL, 0);
    size_t pos = 0;
    PF_CHECK(pf_text_undo(t, &pos) == 0);
    PF_CHECK(pf_text_redo(t, &pos) == 0);

    insert(t, 0, "a");
    insert(t, 1, "b");
    insert(t, 2, "c"); /* one group: no boundaries */
    pf_text_undo_boundary(t);
    insert(t, 3, " d");
    CHECK_TEXT(t, "abc d");

    PF_CHECK(pf_text_undo(t, &pos) == 1);
    CHECK_TEXT(t, "abc");
    PF_CHECK_EQ_SIZE(pos, 3);
    PF_CHECK(pf_text_undo(t, &pos) == 1);
    CHECK_TEXT(t, "");
    PF_CHECK_EQ_SIZE(pos, 0);
    PF_CHECK(pf_text_undo(t, &pos) == 0);

    PF_CHECK(pf_text_redo(t, &pos) == 1);
    CHECK_TEXT(t, "abc");
    PF_CHECK_EQ_SIZE(pos, 3);
    PF_CHECK(pf_text_redo(t, &pos) == 1);
    CHECK_TEXT(t, "abc d");
    PF_CHECK(pf_text_redo(t, &pos) == 0);

    /* Backspace runs coalesce into one change that undoes in one step. */
    pf_text_undo_boundary(t);
    pf_text_delete(t, 4, 5);
    pf_text_delete(t, 3, 4);
    pf_text_delete(t, 2, 3);
    CHECK_TEXT(t, "ab");
    PF_CHECK(pf_text_undo(t, &pos) == 1);
    CHECK_TEXT(t, "abc d");
    PF_CHECK_EQ_SIZE(pos, 2);
    pf_text_free(t);
}

static void test_undo_branches(void) {
    pf_text *t = pf_text_new(NULL, 0);
    insert(t, 0, "a");
    pf_text_undo_boundary(t);
    insert(t, 1, "b");
    PF_CHECK(pf_text_undo(t, NULL) == 1);
    CHECK_TEXT(t, "a");
    insert(t, 1, "c"); /* new branch beside "ab" */
    CHECK_TEXT(t, "ac");
    PF_CHECK(pf_text_undo(t, NULL) == 1);
    CHECK_TEXT(t, "a");
    PF_CHECK_EQ_SIZE(pf_text_redo_branches(t), 2);

    PF_CHECK(pf_text_redo(t, NULL) == 1); /* most recent branch */
    CHECK_TEXT(t, "ac");
    PF_CHECK(pf_text_undo(t, NULL) == 1);
    PF_CHECK(pf_text_select_redo_branch(t, 0) == 0);
    PF_CHECK(pf_text_redo(t, NULL) == 1);
    CHECK_TEXT(t, "ab"); /* the older branch is still there */
    PF_CHECK(pf_text_select_redo_branch(t, 5) == -1);
    pf_text_free(t);
}

static void test_modified(void) {
    pf_text *t = pf_text_new("x", 1);
    PF_CHECK(!pf_text_modified(t));
    insert(t, 1, "y");
    PF_CHECK(pf_text_modified(t));
    pf_text_undo(t, NULL);
    PF_CHECK(!pf_text_modified(t)); /* undone back to the saved tree */
    pf_text_redo(t, NULL);
    pf_text_mark_saved(t);
    PF_CHECK(!pf_text_modified(t));
    pf_text_undo(t, NULL);
    PF_CHECK(pf_text_modified(t));

    /* Same bytes but different history still counts as modified, as in Emacs. */
    pf_text_redo(t, NULL);
    pf_text_undo_boundary(t);
    insert(t, 2, "z");
    pf_text_delete(t, 2, 3);
    CHECK_TEXT(t, "xy");
    PF_CHECK(pf_text_modified(t));
    pf_text_free(t);
}

/* With recording off (an echo area), edits leave no history, the earlier history is gone (it
 * would graft "c" back into unrelated text), and markers still move. */
static void test_undo_disabled(void) {
    pf_text *t = pf_text_new("ab", 2);
    insert(t, 2, "c");
    pf_text_undo_boundary(t);
    pf_text_set_undo(t, 0);
    PF_CHECK(pf_text_modified(t)); /* kept */
    pf_marker m = pf_marker_new(t, 1, 0);
    pf_text_delete(t, 0, 3);
    insert(t, 0, "message");
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, m), 0);
    pf_text_undo_boundary(t);
    PF_CHECK(pf_text_undo(t, NULL) == 0);
    CHECK_TEXT(t, "message");
    pf_text_mark_saved(t);
    insert(t, 0, "more ");
    PF_CHECK(!pf_text_modified(t));

    pf_text_set_undo(t, 1);
    insert(t, 0, "x");
    pf_text_undo_boundary(t);
    PF_CHECK(pf_text_modified(t));
    PF_CHECK(pf_text_undo(t, NULL) == 1);
    CHECK_TEXT(t, "more message");
    pf_text_free(t);
}

static void test_markers_follow_undo(void) {
    pf_text *t = pf_text_new("hello world", 11);
    pf_marker w = pf_marker_new(t, 6, 0); /* at "world" */
    pf_text_delete(t, 0, 6);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, w), 0);
    pf_text_undo(t, NULL);
    /* A marker inside or at the edge of deleted text stays at the deletion point. */
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, w), 0);

    pf_marker_set(t, w, 6);
    pf_text_undo_boundary(t);
    insert(t, 0, ">> ");
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, w), 9);
    pf_text_undo(t, NULL);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, w), 6);
    pf_text_redo(t, NULL);
    PF_CHECK_EQ_SIZE(pf_marker_pos(t, w), 9);
    pf_text_free(t);
}

static void test_snapshot_survives_undo(void) {
    pf_text *t = pf_text_new("abc", 3);
    insert(t, 3, "def");
    const pf_text_snapshot *s = pf_text_snapshot_retain(pf_text_current(t));
    pf_text_undo(t, NULL);
    CHECK_TEXT(t, "abc");
    char buf[6];
    PF_CHECK_EQ_SIZE(pf_text_copy(s, 0, 6, buf, 6), 6);
    PF_CHECK(memcmp(buf, "abcdef", 6) == 0);
    pf_text_free(t);
    pf_text_snapshot_release(s);
}

/* Random edits, boundaries, undos and redos checked against a linear history model (redo in
 * the tree follows the newest branch, which is what the model's truncation describes). */
static uint64_t rng = 0x9E3779B97F4A7C15ull;

static uint32_t rnd(uint32_t bound) {
    rng ^= rng << 13;
    rng ^= rng >> 7;
    rng ^= rng << 17;
    return (uint32_t)(rng % bound);
}

static void test_fuzz(void) {
    enum { MAX_STATES = 4096 };
    char **hist = calloc(MAX_STATES, sizeof *hist);
    size_t at = 0, top = 0; /* hist[at] is current; hist[at+1..top] are redoable */
    pf_text *t = pf_text_new(NULL, 0);
    hist[0] = contents(t);
    int open = 0;

    for (int op = 0; op < 6000 && top + 1 < MAX_STATES; op++) {
        uint32_t r = rnd(100);
        if (r < 55) {
            size_t chars = pf_text_chars(pf_text_current(t));
            if (rnd(3) == 0 && chars > 0) {
                size_t s = rnd((uint32_t)chars), e = s + 1 + rnd(4);
                pf_text_delete(t, s, e);
            } else {
                static const char *words[] = {"a", "bc", "\xC3\xA9", "\n", "xyz "};
                insert(t, rnd((uint32_t)chars + 1), words[rnd(5)]);
            }
            char *now = contents(t);
            if (!open) {
                at++;
                for (size_t i = at; i <= top; i++) {
                    free(hist[i]);
                    hist[i] = NULL;
                }
                top = at;
                open = 1;
            } else {
                free(hist[at]);
            }
            hist[at] = now;
        } else if (r < 70) {
            pf_text_undo_boundary(t);
            open = 0;
        } else if (r < 85) {
            int did = pf_text_undo(t, NULL);
            PF_CHECK(did == (at > 0));
            if (did) {
                at--;
            }
            open = 0;
        } else {
            int did = pf_text_redo(t, NULL);
            PF_CHECK(did == (at < top));
            if (did) {
                at++;
            }
            open = 0;
        }
        CHECK_TEXT(t, hist[at]);
    }
    for (size_t i = 0; i <= top; i++) {
        free(hist[i]);
    }
    free(hist);
    pf_text_free(t);
}

int main(void) {
    test_markers();
    test_markers_while_typing();
    test_undo_groups();
    test_undo_branches();
    test_modified();
    test_undo_disabled();
    test_markers_follow_undo();
    test_snapshot_survives_undo();
    test_fuzz();
    return PF_TEST_RESULT();
}
