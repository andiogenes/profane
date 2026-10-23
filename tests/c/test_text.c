/* Piece tree: fuzzed against a flat reference model, plus snapshot, typing and raw-byte cases. */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "pf_test.h"
#include "pf_text.h"

/* Reference model: an array of characters, each holding its UTF-8 bytes. */
typedef struct ref_char {
    unsigned char len;
    char b[4];
} ref_char;

typedef struct ref {
    ref_char *c;
    size_t n, cap;
} ref;

static uint64_t rng_state = 0x243F6A8885A308D3ull;

static uint32_t rnd(uint32_t bound) {
    rng_state ^= rng_state << 13;
    rng_state ^= rng_state >> 7;
    rng_state ^= rng_state << 17;
    return bound ? (uint32_t)(rng_state % bound) : 0;
}

static ref_char random_char(void) {
    static const char *samples[] = {"a", "b", "z", " ", "\n", "\n", "\xC3\xA9", "\xE2\x80\x94",
                                    "\xF0\x9F\x98\x80", "(", ")"};
    const char *s = samples[rnd(sizeof samples / sizeof samples[0])];
    ref_char c = {(unsigned char)strlen(s), {0}};
    memcpy(c.b, s, c.len);
    return c;
}

static void ref_insert(ref *r, size_t pos, const ref_char *cs, size_t n) {
    if (r->n + n > r->cap) {
        r->cap = (r->n + n) * 2;
        r->c = realloc(r->c, r->cap * sizeof *r->c);
    }
    memmove(r->c + pos + n, r->c + pos, (r->n - pos) * sizeof *r->c);
    memcpy(r->c + pos, cs, n * sizeof *cs);
    r->n += n;
}

static void ref_delete(ref *r, size_t start, size_t end) {
    memmove(r->c + start, r->c + end, (r->n - end) * sizeof *r->c);
    r->n -= end - start;
}

static size_t ref_bytes(const ref *r, size_t start, size_t end, char *out) {
    size_t len = 0;
    for (size_t i = start; i < end; i++) {
        if (out) {
            memcpy(out + len, r->c[i].b, r->c[i].len);
        }
        len += r->c[i].len;
    }
    return len;
}

typedef struct concat {
    char *buf;
    size_t len;
} concat;

static int append_chunk(const char *bytes, size_t len, void *ctx) {
    concat *c = ctx;
    memcpy(c->buf + c->len, bytes, len);
    c->len += len;
    return 0;
}

static void check_against(const pf_text_snapshot *s, const ref *r) {
    size_t total = ref_bytes(r, 0, r->n, NULL);
    PF_CHECK_EQ_SIZE(pf_text_chars(s), r->n);
    PF_CHECK_EQ_SIZE(pf_text_bytes(s), total);

    char *want = malloc(total + 1), *got = malloc(total + 1);
    ref_bytes(r, 0, r->n, want);
    PF_CHECK_EQ_SIZE(pf_text_copy(s, 0, r->n, got, total), total);
    PF_CHECK(memcmp(want, got, total) == 0);

    size_t newlines = 0;
    for (size_t i = 0; i < r->n; i++) {
        newlines += r->c[i].len == 1 && r->c[i].b[0] == '\n';
    }
    PF_CHECK_EQ_SIZE(pf_text_lines(s), newlines + 1);

    /* Prefix tables over the model: byte offset, line and line start of every position. */
    size_t *byte_at = malloc((r->n + 1) * sizeof *byte_at);
    size_t *line_at = malloc((r->n + 1) * sizeof *line_at);
    size_t *start_at = malloc((r->n + 1) * sizeof *start_at);
    byte_at[0] = line_at[0] = start_at[0] = 0;
    for (size_t i = 0; i < r->n; i++) {
        int nl = r->c[i].len == 1 && r->c[i].b[0] == '\n';
        byte_at[i + 1] = byte_at[i] + r->c[i].len;
        line_at[i + 1] = line_at[i] + (size_t)nl;
        start_at[i + 1] = nl ? i + 1 : start_at[i];
    }

    /* Sampled positions: conversions, line lookups, chunked ranges. */
    for (int k = 0; k < 20; k++) {
        size_t pos = rnd((uint32_t)r->n + 1);
        size_t byte = byte_at[pos];
        PF_CHECK_EQ_SIZE(pf_text_char_to_byte(s, pos), byte);
        PF_CHECK_EQ_SIZE(pf_text_byte_to_char(s, byte), pos);
        if (pos < r->n && r->c[pos].len > 1) {
            PF_CHECK_EQ_SIZE(pf_text_byte_to_char(s, byte + 1), pos); /* mid-character */
        }
        PF_CHECK_EQ_SIZE(pf_text_line_of(s, pos), line_at[pos]);
        PF_CHECK_EQ_SIZE(pf_text_line_start(s, line_at[pos]), start_at[pos]);

        size_t end = pos + rnd((uint32_t)(r->n - pos) + 1);
        concat c = {got, 0};
        pf_text_for_each_chunk(s, pos, end, append_chunk, &c);
        size_t want_len = byte_at[end] - byte_at[pos];
        PF_CHECK_EQ_SIZE(c.len, want_len);
        PF_CHECK(memcmp(want + byte, got, want_len) == 0);
    }
    free(byte_at);
    free(line_at);
    free(start_at);
    PF_CHECK_EQ_SIZE(pf_text_line_start(s, newlines + 5), r->n);
    free(want);
    free(got);
}

static void encode(const ref_char *cs, size_t n, char *out, size_t *len) {
    *len = 0;
    for (size_t i = 0; i < n; i++) {
        memcpy(out + *len, cs[i].b, cs[i].len);
        *len += cs[i].len;
    }
}

typedef struct kept {
    const pf_text_snapshot *snap;
    ref model;
} kept;

static void test_fuzz(void) {
    ref r = {0};
    pf_text *t = pf_text_new(NULL, 0);
    kept keep[16];
    size_t nkeep = 0;
    ref_char *cs = malloc(20000 * sizeof *cs);
    char *bytes = malloc(20000 * 4);

    for (int op = 1; op <= 20000; op++) {
        if (r.n == 0 || rnd(100) < 60) {
            size_t n = rnd(100) == 0 ? 2000 + rnd(15000) : 1 + rnd(12); /* rare large insert */
            for (size_t i = 0; i < n; i++) {
                cs[i] = random_char();
            }
            size_t pos = rnd(4) == 0 ? r.n : rnd((uint32_t)r.n + 1); /* often typing at end */
            size_t len;
            encode(cs, n, bytes, &len);
            PF_CHECK(pf_text_insert(t, pos, bytes, len) == 0);
            ref_insert(&r, pos, cs, n);
        } else {
            size_t start = rnd((uint32_t)r.n);
            size_t end = start + 1 + rnd(rnd(20) == 0 ? 5000 : 10);
            end = end < r.n ? end : r.n;
            pf_text_delete(t, start, end);
            ref_delete(&r, start, end);
        }
        if (op % 97 == 0) {
            check_against(pf_text_current(t), &r);
        }
        if (op % 1300 == 0 && nkeep < 16) {
            keep[nkeep].snap = pf_text_snapshot_retain(pf_text_current(t));
            keep[nkeep].model.n = keep[nkeep].model.cap = r.n;
            keep[nkeep].model.c = malloc((r.n + 1) * sizeof *r.c);
            memcpy(keep[nkeep].model.c, r.c, r.n * sizeof *r.c);
            nkeep++;
        }
    }
    check_against(pf_text_current(t), &r);

    /* Old snapshots are unaffected by later edits and outlive the document. */
    pf_text_free(t);
    for (size_t i = 0; i < nkeep; i++) {
        check_against(keep[i].snap, &keep[i].model);
        pf_text_snapshot_release(keep[i].snap);
        free(keep[i].model.c);
    }
    free(r.c);
    free(cs);
    free(bytes);
}

static void test_empty(void) {
    pf_text *t = pf_text_new(NULL, 0);
    const pf_text_snapshot *s = pf_text_current(t);
    PF_CHECK_EQ_SIZE(pf_text_bytes(s), 0);
    PF_CHECK_EQ_SIZE(pf_text_chars(s), 0);
    PF_CHECK_EQ_SIZE(pf_text_lines(s), 1);
    PF_CHECK_EQ_SIZE(pf_text_line_start(s, 0), 0);
    PF_CHECK_EQ_SIZE(pf_text_line_start(s, 3), 0);
    PF_CHECK_EQ_SIZE(pf_text_line_of(s, 0), 0);
    PF_CHECK_EQ_SIZE(pf_text_copy(s, 0, 10, NULL, 0), 0);
    pf_text_delete(t, 0, 5);
    PF_CHECK(pf_text_insert(t, 99, "x", 1) == 0); /* clamped to the end */
    PF_CHECK_EQ_SIZE(pf_text_chars(pf_text_current(t)), 1);
    pf_text_free(t);
}

static void test_typing_reuses_pieces(void) {
    pf_text *t = pf_text_new("hello\n", 6);
    for (int i = 0; i < 3000; i++) {
        PF_CHECK(pf_text_insert(t, pf_text_chars(pf_text_current(t)), "x", 1) == 0);
    }
    const pf_text_snapshot *s = pf_text_current(t);
    PF_CHECK_EQ_SIZE(pf_text_chars(s), 3006);
    PF_CHECK(pf_text_piece_count(s) <= 3);

    /* Backspace then retype: the bytes no longer abut, so a new piece starts. */
    pf_text_delete(t, 3005, 3006);
    PF_CHECK(pf_text_insert(t, 3005, "y", 1) == 0);
    char last[2];
    pf_text_copy(pf_text_current(t), 3004, 3006, last, 2);
    PF_CHECK(memcmp(last, "xy", 2) == 0);
    pf_text_free(t);
}

static void test_large_text_depth(void) {
    size_t len = 8 * 1024 * 1024;
    char *buf = malloc(len);
    for (size_t i = 0; i < len; i++) {
        buf[i] = i % 80 == 79 ? '\n' : (char)('a' + i % 26);
    }
    pf_text *t = pf_text_new(buf, len);
    const pf_text_snapshot *s = pf_text_current(t);
    PF_CHECK_EQ_SIZE(pf_text_bytes(s), len);
    PF_CHECK_EQ_SIZE(pf_text_lines(s), len / 80 + 1);
    PF_CHECK(pf_text_depth(s) < 64); /* ~2000 pieces; a treap stays logarithmic */
    PF_CHECK_EQ_SIZE(pf_text_line_start(s, 50000), 50000 * 80);
    PF_CHECK_EQ_SIZE(pf_text_line_of(s, 50000 * 80 + 3), 50000);
    pf_text_free(t);
    free(buf);
}

/* Regression: split halves used to share one priority, so many edits inside the same pieces
 * piled up ties and roughly doubled the depth. */
static void test_random_edits_stay_balanced(void) {
    size_t len = 1024 * 1024;
    char *buf = malloc(len);
    memset(buf, 'a', len);
    pf_text *t = pf_text_new(buf, len);
    for (int i = 0; i < 50000; i++) {
        PF_CHECK(pf_text_insert(t, rnd((uint32_t)len), "y", 1) == 0);
    }
    const pf_text_snapshot *s = pf_text_current(t);
    PF_CHECK(pf_text_piece_count(s) > 50000);
    PF_CHECK(pf_text_depth(s) < 60); /* ~2.99 ln n = 33 expected; ties pushed it past 60 */
    pf_text_free(t);
    free(buf);
}

static void test_raw_bytes(void) {
    /* E2 is a truncated lead (next byte 'a'), 80 and 94 are stray continuations: 4 chars. */
    pf_text *t = pf_text_new("\xE2" "a\x80\x94", 4);
    PF_CHECK_EQ_SIZE(pf_text_chars(pf_text_current(t)), 4);

    /* Deleting 'a' does not fuse the raw bytes into U+2014; bytes are kept exactly. */
    pf_text_delete(t, 1, 2);
    const pf_text_snapshot *s = pf_text_current(t);
    PF_CHECK_EQ_SIZE(pf_text_chars(s), 3);
    char out[3];
    PF_CHECK_EQ_SIZE(pf_text_copy(s, 0, 3, out, 3), 3);
    PF_CHECK(memcmp(out, "\xE2\x80\x94", 3) == 0);

    /* Overlong and surrogate encodings are raw bytes, not characters. */
    pf_text *u = pf_text_new("\xC0\xAF\xED\xA0\x80", 5);
    PF_CHECK_EQ_SIZE(pf_text_chars(pf_text_current(u)), 5);
    pf_text_free(u);
    pf_text_free(t);
}

int main(void) {
    test_empty();
    test_typing_reuses_pieces();
    test_large_text_depth();
    test_raw_bytes();
    test_random_edits_stay_balanced();
    test_fuzz();
    return PF_TEST_RESULT();
}
