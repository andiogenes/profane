#include "pf_text.h"

#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "pf_props.h"
#include "pf_utf8.h"

/* Pieces are kept small so that work inside one piece (splitting it, finding the n-th newline)
 * stays cheap; a large file becomes many pieces. Storage blocks never move once allocated. */
enum { PIECE_MAX = 4096, BLOCK_SIZE = 64 * 1024 };

/* Append-only byte storage shared by a text and all of its snapshots. */
typedef struct block {
    struct block *next;
    size_t cap, used;
    unsigned char data[];
} block;

typedef struct store {
    atomic_size_t refs;
    block *head; /* newest first; only the head receives appends */
} store;

/* Treap node: one piece plus subtree totals. Immutable once shared. */
typedef struct node {
    atomic_size_t refs;
    uint32_t prio;
    struct node *l, *r;
    const unsigned char *p;
    uint32_t len, chars, lines;
    size_t sb, sc, sl; /* subtree bytes, chars, lines (newlines) */
} node;

struct pf_text_snapshot {
    atomic_size_t refs;
    node *root;
    store *st;
};

/* One edit, in character positions: REMOVED chars at POS were replaced by INSERTED chars.
 * SUB holds the text needed to reverse it: while the change is applied, the removed text (NULL
 * for a pure insertion); while it is undone, the inserted text. Subtrees share pieces with the
 * tree, so history costs about as much as the text it deleted, as Emacs undo lists do.
 * (Keeping a whole root per state was tried first: it pinned ~24 KB per undo state.) */
typedef struct change {
    size_t pos, removed, inserted;
    struct node *sub;
} change;

/* Undo tree state: a group of changes made from PARENT. */
typedef struct ustate {
    struct ustate *parent;
    struct ustate **kids;
    size_t nkids, kcap;
    struct ustate *redo; /* child that redo enters: the most recently created or left */
    change *ch;
    size_t n, cap;
    uint64_t version; /* bumped on every change recorded into this state */
} ustate;

/* Marker handles: low 24 bits are slot + 1, high 8 bits a generation that changes on free. */
enum { MARKER_SLOT_BITS = 24 };
#define MARKER_SLOT_MASK ((1u << MARKER_SLOT_BITS) - 1)

typedef struct marker_slot {
    size_t pos;
    uint8_t gen, live, advances;
} marker_slot;

struct pf_text {
    pf_text_snapshot *cur;
    store *st;
    uint32_t rng;
    pf_props *props;

    marker_slot *markers;
    size_t nmarkers, mcap, mfree_hint;

    ustate *uroot, *ucur;
    int group_open;
    uint64_t versions;
    ustate *saved_state;
    uint64_t saved_version;
    int undo_off;
};

static void *xmalloc(size_t size) {
    void *p = malloc(size);
    if (!p) {
        fputs("profane: out of memory\n", stderr);
        abort();
    }
    return p;
}

/* ---- storage ---- */

static store *store_new(void) {
    store *st = xmalloc(sizeof *st);
    atomic_init(&st->refs, 1);
    st->head = NULL;
    return st;
}

static void store_release(store *st) {
    if (atomic_fetch_sub_explicit(&st->refs, 1, memory_order_acq_rel) != 1) {
        return;
    }
    for (block *b = st->head, *next; b; b = next) {
        next = b->next;
        free(b);
    }
    free(st);
}

/* Copies LEN bytes into storage; NULL if a new block cannot be allocated. */
static const unsigned char *store_append(store *st, const char *bytes, size_t len) {
    block *b = st->head;
    if (!b || b->cap - b->used < len) {
        size_t cap = len > BLOCK_SIZE ? len : BLOCK_SIZE;
        b = malloc(sizeof *b + cap);
        if (!b) {
            return NULL;
        }
        b->cap = cap;
        b->used = 0;
        b->next = st->head;
        st->head = b;
    }
    unsigned char *dst = b->data + b->used;
    memcpy(dst, bytes, len);
    b->used += len;
    return dst;
}

/* ---- nodes ---- */

#define SB(n) ((n) ? (n)->sb : 0)
#define SC(n) ((n) ? (n)->sc : 0)
#define SL(n) ((n) ? (n)->sl : 0)

static node *node_retain(node *n) {
    if (n) {
        atomic_fetch_add_explicit(&n->refs, 1, memory_order_relaxed);
    }
    return n;
}

static void node_release(node *n) {
    if (n && atomic_fetch_sub_explicit(&n->refs, 1, memory_order_acq_rel) == 1) {
        node_release(n->l);
        node_release(n->r);
        free(n);
    }
}

/* Takes ownership of L and R. */
static node *node_new(uint32_t prio, node *l, node *r, const unsigned char *p, size_t len,
                      size_t chars, size_t lines) {
    node *n = xmalloc(sizeof *n);
    atomic_init(&n->refs, 1);
    n->prio = prio;
    n->l = l;
    n->r = r;
    n->p = p;
    n->len = (uint32_t)len;
    n->chars = (uint32_t)chars;
    n->lines = (uint32_t)lines;
    n->sb = SB(l) + len + SB(r);
    n->sc = SC(l) + chars + SC(r);
    n->sl = SL(l) + lines + SL(r);
    return n;
}

static size_t count_newlines(const unsigned char *p, size_t len) {
    size_t count = 0;
    const unsigned char *end = p + len;
    while ((p = memchr(p, '\n', (size_t)(end - p)))) {
        count++;
        p++;
    }
    return count;
}

/* Byte offset of character K within a piece. */
static size_t piece_offset(const node *n, size_t k) {
    return n->chars == n->len ? k : pf_utf8_unit_offset(n->p, n->len, k);
}

static uint32_t next_prio(pf_text *t) {
    /* xorshift32: deterministic, so tree shapes are reproducible in tests. */
    uint32_t x = t->rng;
    x ^= x << 13;
    x ^= x >> 17;
    x ^= x << 5;
    return t->rng = x;
}

/* Concatenates A and B, consuming both. */
static node *merge(node *a, node *b);

/* Splits the subtree N (borrowed) at character C into owned L and R. */
static void split(pf_text *t, node *n, size_t c, node **L, node **R) {
    if (!n) {
        *L = *R = NULL;
        return;
    }
    if (c == 0) {
        *L = NULL;
        *R = node_retain(n);
        return;
    }
    if (c >= n->sc) {
        *L = node_retain(n);
        *R = NULL;
        return;
    }
    size_t lc = SC(n->l);
    if (c <= lc) {
        node *a, *b;
        split(t, n->l, c, &a, &b);
        *L = a;
        *R = node_new(n->prio, b, node_retain(n->r), n->p, n->len, n->chars, n->lines);
    } else if (c >= lc + n->chars) {
        node *a, *b;
        split(t, n->r, c - lc - n->chars, &a, &b);
        *L = node_new(n->prio, node_retain(n->l), a, n->p, n->len, n->chars, n->lines);
        *R = b;
    } else {
        /* Inside this piece. The left half keeps the node's priority (heap order holds); the
         * right half is a new piece with a fresh priority, merged back in, so repeated splits
         * of one piece do not pile up equal priorities and unbalance the tree. */
        size_t k = c - lc;
        size_t off = piece_offset(n, k);
        size_t lines = count_newlines(n->p, off);
        *L = node_new(n->prio, node_retain(n->l), NULL, n->p, off, k, lines);
        *R = merge(node_new(next_prio(t), NULL, NULL, n->p + off, n->len - off, n->chars - k,
                            n->lines - lines),
                   node_retain(n->r));
    }
}

static node *merge(node *a, node *b) {
    if (!a) {
        return b;
    }
    if (!b) {
        return a;
    }
    node *n;
    if (a->prio >= b->prio) {
        n = node_new(a->prio, node_retain(a->l), merge(node_retain(a->r), b), a->p, a->len,
                     a->chars, a->lines);
        node_release(a);
    } else {
        n = node_new(b->prio, merge(a, node_retain(b->l)), node_retain(b->r), b->p, b->len,
                     b->chars, b->lines);
        node_release(b);
    }
    return n;
}

static const node *rightmost(const node *n) {
    while (n->r) {
        n = n->r;
    }
    return n;
}

/* Copy of N (borrowed) whose last piece is ADD_LEN bytes longer. */
static node *extend_rightmost(const node *n, size_t add_len, size_t add_chars, size_t add_lines) {
    if (n->r) {
        return node_new(n->prio, node_retain(n->l),
                        extend_rightmost(n->r, add_len, add_chars, add_lines), n->p, n->len,
                        n->chars, n->lines);
    }
    return node_new(n->prio, node_retain(n->l), NULL, n->p, n->len + add_len,
                    n->chars + add_chars, n->lines + add_lines);
}


/* Builds a subtree of pieces over stored bytes P[0..LEN), cut at character boundaries. */
static node *build(pf_text *t, const unsigned char *p, size_t len) {
    node *root = NULL;
    size_t start = 0;
    while (start < len) {
        size_t end = start, chars = 0;
        while (end < len) {
            size_t u = p[end] < 0x80 ? 1 : pf_utf8_unit_len(p + end, len - end);
            if (end - start + u > PIECE_MAX) {
                break;
            }
            end += u;
            chars++;
        }
        size_t n = end - start;
        root = merge(root, node_new(next_prio(t), NULL, NULL, p + start, n, chars,
                                    count_newlines(p + start, n)));
        start = end;
    }
    return root;
}

/* ---- snapshots ---- */

static pf_text_snapshot *snapshot_new(store *st, node *root) {
    pf_text_snapshot *s = xmalloc(sizeof *s);
    atomic_init(&s->refs, 1);
    s->root = root;
    s->st = st;
    atomic_fetch_add_explicit(&st->refs, 1, memory_order_relaxed);
    return s;
}

const pf_text_snapshot *pf_text_snapshot_retain(const pf_text_snapshot *snap) {
    atomic_fetch_add_explicit(&((pf_text_snapshot *)snap)->refs, 1, memory_order_relaxed);
    return snap;
}

void pf_text_snapshot_release(const pf_text_snapshot *snap) {
    pf_text_snapshot *s = (pf_text_snapshot *)snap;
    if (s && atomic_fetch_sub_explicit(&s->refs, 1, memory_order_acq_rel) == 1) {
        node_release(s->root);
        store_release(s->st);
        free(s);
    }
}

static void replace_root(pf_text *t, node *root) {
    pf_text_snapshot *old = t->cur;
    t->cur = snapshot_new(t->st, root);
    pf_text_snapshot_release(old);
}

/* ---- markers ---- */

static void markers_insert(pf_text *t, size_t pos, size_t n) {
    for (size_t i = 0; i < t->nmarkers; i++) {
        marker_slot *m = &t->markers[i];
        if (m->live && (m->pos > pos || (m->pos == pos && m->advances))) {
            m->pos += n;
        }
    }
}

static void markers_delete(pf_text *t, size_t start, size_t end) {
    for (size_t i = 0; i < t->nmarkers; i++) {
        marker_slot *m = &t->markers[i];
        if (m->live && m->pos > start) {
            m->pos = m->pos >= end ? m->pos - (end - start) : start;
        }
    }
}

/* Moves markers and text properties for change C (or its inverse, for undo). */
static void markers_apply(pf_text *t, const change *c, int inverse) {
    size_t removed = inverse ? c->inserted : c->removed;
    size_t inserted = inverse ? c->removed : c->inserted;
    markers_delete(t, c->pos, c->pos + removed);
    markers_insert(t, c->pos, inserted);
    pf_props_delete(t->props, c->pos, c->pos + removed);
    pf_props_insert(t->props, c->pos, inserted);
}

static marker_slot *marker_get(const pf_text *t, pf_marker m) {
    size_t slot = (m & MARKER_SLOT_MASK);
    if (slot == 0 || slot > t->nmarkers) {
        return NULL;
    }
    marker_slot *ms = &t->markers[slot - 1];
    return ms->live && ms->gen == (uint8_t)(m >> MARKER_SLOT_BITS) ? ms : NULL;
}

/* ---- undo ---- */

static ustate *ustate_new(ustate *parent) {
    ustate *u = xmalloc(sizeof *u);
    memset(u, 0, sizeof *u);
    u->parent = parent;
    if (parent) {
        if (parent->nkids == parent->kcap) {
            parent->kcap = parent->kcap ? parent->kcap * 2 : 2;
            parent->kids = realloc(parent->kids, parent->kcap * sizeof *parent->kids);
            if (!parent->kids) {
                fputs("profane: out of memory\n", stderr);
                abort();
            }
        }
        parent->kids[parent->nkids++] = u;
        parent->redo = u;
    }
    return u;
}

static void ustate_free(ustate *u) {
    for (size_t i = 0; i < u->nkids; i++) {
        ustate_free(u->kids[i]);
    }
    free(u->kids);
    for (size_t i = 0; i < u->n; i++) {
        node_release(u->ch[i].sub);
    }
    free(u->ch);
    free(u);
}

/* Records change C (taking ownership of C.sub) in the open undo group, opening one if needed.
 * Runs of typing (inserts continuing the last insert) and of deletions abutting the last one
 * coalesce into a single change. */
static void undo_record(pf_text *t, change c) {
    if (t->undo_off) {
        node_release(c.sub);
        return;
    }
    if (!t->group_open) {
        t->ucur = ustate_new(t->ucur);
        t->group_open = 1;
    }
    ustate *u = t->ucur;
    u->version = ++t->versions;
    change *last = u->n ? &u->ch[u->n - 1] : NULL;
    if (last && last->removed == 0 && c.removed == 0 && c.pos == last->pos + last->inserted) {
        last->inserted += c.inserted;
        return;
    }
    if (last && last->inserted == 0 && c.inserted == 0) {
        if (c.pos + c.removed == last->pos) { /* backspace run */
            last->pos = c.pos;
            last->removed += c.removed;
            last->sub = merge(c.sub, last->sub);
            return;
        }
        if (c.pos == last->pos) { /* delete-char run */
            last->removed += c.removed;
            last->sub = merge(last->sub, c.sub);
            return;
        }
    }
    if (u->n == u->cap) {
        u->cap = u->cap ? u->cap * 2 : 4;
        u->ch = realloc(u->ch, u->cap * sizeof *u->ch);
        if (!u->ch) {
            fputs("profane: out of memory\n", stderr);
            abort();
        }
    }
    u->ch[u->n++] = c;
}

void pf_text_set_undo(pf_text *t, int enabled) {
    if (!enabled && !t->undo_off) {
        /* The history stops matching the text once edits go unrecorded: drop it, as Emacs
         * does. The modified flag is kept. */
        int modified = pf_text_modified(t);
        ustate_free(t->uroot);
        t->uroot = t->ucur = ustate_new(NULL);
        t->saved_state = modified ? NULL : t->ucur;
        t->saved_version = t->ucur->version;
    }
    t->undo_off = !enabled;
    t->group_open = 0;
}

/* Installs ROOT (consumed) as the result of change C: moves markers and records undo. */
static void commit(pf_text *t, node *root, change c) {
    markers_apply(t, &c, 0);
    undo_record(t, c);
    replace_root(t, root);
}

/* Applies C (forward) or its inverse to ROOT (consumed) by swapping the text at C.pos with
 * C.sub; C.sub then holds the text taken out. Returns the new root. */
static node *swap_change(pf_text *t, node *root, change *c, int inverse) {
    size_t take = inverse ? c->inserted : c->removed;
    node *L, *X, *out, *R;
    split(t, root, c->pos, &L, &X);
    split(t, X, take, &out, &R);
    node_release(X);
    node_release(root);
    node *in = c->sub;
    c->sub = out;
    markers_apply(t, c, inverse);
    return merge(merge(L, in), R);
}

/* ---- documents ---- */

pf_text *pf_text_new(const char *bytes, size_t len) {
    pf_text *t = malloc(sizeof *t);
    if (!t) {
        return NULL;
    }
    t->st = store_new();
    t->rng = 0x9E3779B9u;
    node *root = NULL;
    if (len > 0) {
        const unsigned char *p = store_append(t->st, bytes, len);
        if (!p) {
            store_release(t->st);
            free(t);
            return NULL;
        }
        root = build(t, p, len);
    }
    t->cur = snapshot_new(t->st, root);
    t->props = pf_props_new();
    t->markers = NULL;
    t->nmarkers = t->mcap = t->mfree_hint = 0;
    t->uroot = t->ucur = ustate_new(NULL);
    t->group_open = 0;
    t->versions = 0;
    t->saved_state = t->uroot;
    t->saved_version = 0;
    t->undo_off = 0;
    return t;
}

void pf_text_free(pf_text *text) {
    if (text) {
        ustate_free(text->uroot);
        pf_props_free(text->props);
        free(text->markers);
        pf_text_snapshot_release(text->cur);
        store_release(text->st);
        free(text);
    }
}

pf_props *pf_text_props(pf_text *text) {
    return text->props;
}

const pf_text_snapshot *pf_text_current(const pf_text *text) {
    return text->cur;
}

int pf_text_insert(pf_text *text, size_t pos, const char *bytes, size_t len) {
    if (len == 0) {
        return 0;
    }
    const unsigned char *p = store_append(text->st, bytes, len);
    if (!p) {
        return -1;
    }
    node *L, *R, *mid = NULL;
    split(text, text->cur->root, pos, &L, &R);
    size_t at = SC(L); /* POS clamped; read before L is extended below */

    /* Typing: extend the piece just before POS when its bytes end where these were stored.
     * A leading continuation byte could fuse with that piece's tail, so it never extends. */
    const node *last = L ? rightmost(L) : NULL;
    if (last && last->p + last->len == p && last->len + len <= PIECE_MAX && (p[0] & 0xC0) != 0x80) {
        node *extended = extend_rightmost(L, len, pf_utf8_count_units(p, len),
                                          count_newlines(p, len));
        node_release(L);
        L = extended;
    } else {
        mid = build(text, p, len);
    }
    commit(text, merge(merge(L, mid), R), (change){at, 0, pf_utf8_count_units(p, len), NULL});
    return 0;
}

void pf_text_delete(pf_text *text, size_t start, size_t end) {
    size_t chars = SC(text->cur->root);
    end = end < chars ? end : chars;
    if (start >= end) {
        return;
    }
    node *L, *X, *M, *R;
    split(text, text->cur->root, start, &L, &X);
    split(text, X, end - start, &M, &R);
    node_release(X);
    commit(text, merge(L, R), (change){start, end - start, 0, M}); /* M kept for undo */
}

/* ---- public markers ---- */

pf_marker pf_marker_new(pf_text *text, size_t pos, int advances) {
    size_t chars = SC(text->cur->root);
    size_t slot = text->mfree_hint;
    while (slot < text->nmarkers && text->markers[slot].live) {
        slot++;
    }
    if (slot == text->nmarkers) {
        if (slot >= MARKER_SLOT_MASK) {
            return 0;
        }
        if (text->nmarkers == text->mcap) {
            size_t cap = text->mcap ? text->mcap * 2 : 16;
            marker_slot *m = realloc(text->markers, cap * sizeof *m);
            if (!m) {
                return 0;
            }
            text->markers = m;
            text->mcap = cap;
        }
        text->markers[text->nmarkers++] = (marker_slot){0, 0, 0, 0};
    }
    marker_slot *m = &text->markers[slot];
    m->pos = pos < chars ? pos : chars;
    m->live = 1;
    m->advances = advances != 0;
    text->mfree_hint = slot + 1;
    return (pf_marker)((uint32_t)m->gen << MARKER_SLOT_BITS | (uint32_t)(slot + 1));
}

void pf_marker_free(pf_text *text, pf_marker marker) {
    marker_slot *m = marker_get(text, marker);
    if (m) {
        m->live = 0;
        m->gen++;
        size_t slot = (size_t)(m - text->markers);
        if (slot < text->mfree_hint) {
            text->mfree_hint = slot;
        }
    }
}

size_t pf_marker_pos(const pf_text *text, pf_marker marker) {
    const marker_slot *m = marker_get(text, marker);
    return m ? m->pos : SIZE_MAX;
}

int pf_marker_set(pf_text *text, pf_marker marker, size_t pos) {
    marker_slot *m = marker_get(text, marker);
    if (!m) {
        return -1;
    }
    size_t chars = SC(text->cur->root);
    m->pos = pos < chars ? pos : chars;
    return 0;
}

/* ---- public undo ---- */

void pf_text_undo_boundary(pf_text *text) {
    text->group_open = 0;
}

int pf_text_undo(pf_text *text, size_t *pos) {
    text->group_open = 0;
    ustate *u = text->ucur;
    if (!u->parent) {
        return 0;
    }
    node *root = node_retain(text->cur->root);
    for (size_t i = u->n; i-- > 0;) {
        root = swap_change(text, root, &u->ch[i], 1);
    }
    if (pos) {
        *pos = u->ch[0].pos;
    }
    u->parent->redo = u;
    text->ucur = u->parent;
    replace_root(text, root);
    return 1;
}

int pf_text_redo(pf_text *text, size_t *pos) {
    text->group_open = 0;
    ustate *u = text->ucur->redo;
    if (!u) {
        return 0;
    }
    node *root = node_retain(text->cur->root);
    for (size_t i = 0; i < u->n; i++) {
        root = swap_change(text, root, &u->ch[i], 0);
    }
    if (pos) {
        *pos = u->ch[u->n - 1].pos + u->ch[u->n - 1].inserted;
    }
    text->ucur = u;
    replace_root(text, root);
    return 1;
}

size_t pf_text_redo_branches(const pf_text *text) {
    return text->ucur->nkids;
}

int pf_text_select_redo_branch(pf_text *text, size_t index) {
    if (index >= text->ucur->nkids) {
        return -1;
    }
    text->ucur->redo = text->ucur->kids[index];
    return 0;
}

void pf_text_mark_saved(pf_text *text) {
    text->saved_state = text->ucur;
    text->saved_version = text->ucur->version;
}

int pf_text_modified(const pf_text *text) {
    return text->ucur != text->saved_state || text->ucur->version != text->saved_version;
}

/* ---- queries ---- */

size_t pf_text_bytes(const pf_text_snapshot *snap) {
    return SB(snap->root);
}

size_t pf_text_chars(const pf_text_snapshot *snap) {
    return SC(snap->root);
}

size_t pf_text_lines(const pf_text_snapshot *snap) {
    return SL(snap->root) + 1;
}

size_t pf_text_char_to_byte(const pf_text_snapshot *snap, size_t pos) {
    size_t acc = 0;
    for (const node *n = snap->root; n;) {
        size_t lc = SC(n->l);
        if (pos < lc) {
            n = n->l;
        } else if (pos < lc + n->chars) {
            return acc + SB(n->l) + piece_offset(n, pos - lc);
        } else {
            pos -= lc + n->chars;
            acc += SB(n->l) + n->len;
            n = n->r;
        }
    }
    return acc;
}

size_t pf_text_byte_to_char(const pf_text_snapshot *snap, size_t byte) {
    size_t acc = 0;
    for (const node *n = snap->root; n;) {
        size_t lb = SB(n->l);
        if (byte < lb) {
            n = n->l;
        } else if (byte < lb + n->len) {
            size_t k = byte - lb, i = 0, c = 0;
            while (i < k) {
                size_t u = pf_utf8_unit_len(n->p + i, n->len - i);
                if (i + u > k) {
                    break; /* K is inside this character */
                }
                i += u;
                c++;
            }
            return acc + SC(n->l) + c;
        } else {
            byte -= lb + n->len;
            acc += SC(n->l) + n->chars;
            n = n->r;
        }
    }
    return acc;
}

size_t pf_text_line_start(const pf_text_snapshot *snap, size_t line) {
    if (line == 0) {
        return 0;
    }
    size_t target = line, acc = 0; /* find the position just after newline number TARGET */
    for (const node *n = snap->root; n;) {
        size_t ll = SL(n->l);
        if (target <= ll) {
            n = n->l;
        } else if (target <= ll + n->lines) {
            size_t want = target - ll;
            const unsigned char *q = n->p, *end = n->p + n->len;
            while (want-- > 0) {
                q = (const unsigned char *)memchr(q, '\n', (size_t)(end - q)) + 1;
            }
            size_t off = (size_t)(q - n->p);
            size_t chars = n->chars == n->len ? off : pf_utf8_count_units(n->p, off);
            return acc + SC(n->l) + chars;
        } else {
            target -= ll + n->lines;
            acc += SC(n->l) + n->chars;
            n = n->r;
        }
    }
    return SC(snap->root);
}

size_t pf_text_line_of(const pf_text_snapshot *snap, size_t pos) {
    size_t lines = 0;
    for (const node *n = snap->root; n;) {
        size_t lc = SC(n->l);
        if (pos < lc) {
            n = n->l;
        } else if (pos < lc + n->chars) {
            return lines + SL(n->l) + count_newlines(n->p, piece_offset(n, pos - lc));
        } else {
            pos -= lc + n->chars;
            lines += SL(n->l) + n->lines;
            n = n->r;
        }
    }
    return lines;
}

static int visit(const node *n, size_t start, size_t end, pf_text_chunk_fn fn, void *ctx) {
    if (!n || start >= end) {
        return 0;
    }
    size_t lc = SC(n->l), pc = lc + n->chars;
    int rc;
    if (start < lc && (rc = visit(n->l, start, end < lc ? end : lc, fn, ctx))) {
        return rc;
    }
    size_t ps = start > lc ? start : lc, pe = end < pc ? end : pc;
    if (ps < pe) {
        size_t b0 = piece_offset(n, ps - lc), b1 = piece_offset(n, pe - lc);
        if ((rc = fn((const char *)n->p + b0, b1 - b0, ctx))) {
            return rc;
        }
    }
    if (end > pc) {
        return visit(n->r, start > pc ? start - pc : 0, end - pc, fn, ctx);
    }
    return 0;
}

int pf_text_for_each_chunk(const pf_text_snapshot *snap, size_t start, size_t end,
                           pf_text_chunk_fn fn, void *ctx) {
    return visit(snap->root, start, end, fn, ctx);
}

typedef struct copy_ctx {
    char *out;
    size_t cap, written;
} copy_ctx;

static int copy_chunk(const char *bytes, size_t len, void *ctx) {
    copy_ctx *c = ctx;
    size_t room = c->cap - c->written;
    size_t n = len < room ? len : room;
    memcpy(c->out + c->written, bytes, n);
    c->written += n;
    return c->written == c->cap;
}

size_t pf_text_copy(const pf_text_snapshot *snap, size_t start, size_t end, char *out,
                    size_t cap) {
    size_t total = SC(snap->root);
    end = end < total ? end : total;
    if (start >= end) {
        return 0;
    }
    if (cap > 0) {
        copy_ctx c = {out, cap, 0};
        visit(snap->root, start, end, copy_chunk, &c);
    }
    return pf_text_char_to_byte(snap, end) - pf_text_char_to_byte(snap, start);
}

static size_t count_nodes(const node *n) {
    return n ? 1 + count_nodes(n->l) + count_nodes(n->r) : 0;
}

static size_t depth(const node *n) {
    if (!n) {
        return 0;
    }
    size_t l = depth(n->l), r = depth(n->r);
    return 1 + (l > r ? l : r);
}

size_t pf_text_piece_count(const pf_text_snapshot *snap) {
    return count_nodes(snap->root);
}

size_t pf_text_depth(const pf_text_snapshot *snap) {
    return depth(snap->root);
}
