#ifndef PF_TEXT_H
#define PF_TEXT_H

#include <stddef.h>
#include <stdint.h>

/* Buffer text: a persistent piece tree over append-only UTF-8 storage.
 *
 * A pf_text is the mutable document, owned by the main thread. Every edit produces a new
 * immutable pf_text_snapshot in O(log n) by path copying, sharing all unchanged nodes and bytes.
 * Snapshots are reference counted with atomic counts: retain one and hand it to another thread
 * (render, workers, agents) to read without locks while the main thread keeps editing.
 *
 * Positions are character positions, a character being a UTF-8 "unit" (see pf_utf8.h); lines
 * are counted by '\n'. Characters are counted per piece: a raw invalid byte stays its own
 * character after edits (as Emacs eight-bit chars do) and bytes are never altered, so saving
 * is lossless. */

typedef struct pf_text pf_text;
typedef struct pf_text_snapshot pf_text_snapshot;

/* Returns NULL on allocation failure. BYTES may contain invalid UTF-8. */
pf_text *pf_text_new(const char *bytes, size_t len);
void pf_text_free(pf_text *text);

/* Inserts BYTES at character position POS (clamped to the end). Returns 0, or -1 if the bytes
 * cannot be stored (the text is unchanged). Running out of memory for tree nodes aborts. */
int pf_text_insert(pf_text *text, size_t pos, const char *bytes, size_t len);

/* Deletes characters [START, END) (clamped). */
void pf_text_delete(pf_text *text, size_t start, size_t end);

/* ---- markers ----
 * A marker is a position that follows edits. Text inserted exactly at a marker goes after it
 * unless the marker ADVANCES (Emacs insertion type t). Deleting text around a marker moves it to
 * the start of the deletion. Handles are never 0; freed or foreign handles are rejected. */
typedef uint32_t pf_marker;

pf_marker pf_marker_new(pf_text *text, size_t pos, int advances); /* 0 if out of memory */
void pf_marker_free(pf_text *text, pf_marker marker);
size_t pf_marker_pos(const pf_text *text, pf_marker marker); /* SIZE_MAX if invalid */
int pf_marker_set(pf_text *text, pf_marker marker, size_t pos); /* -1 if invalid */

/* ---- undo ----
 * Edits accumulate into the open undo group until a boundary (the command loop places one
 * after each command). Undo reverses the group by grafting the removed text back in (O(log n)
 * per change); editing after an undo starts a new branch, so no state is lost (undo tree).
 * Markers move with the reversed changes. History is unbounded for now (limits come with M2
 * vars); it costs about as much memory as the text it deleted. */
void pf_text_undo_boundary(pf_text *text);

/* Each returns 1 and sets *POS (if non-NULL) to where point belongs, or 0 if there is nothing
 * to undo/redo. Redo enters the most recently created or left branch. */
int pf_text_undo(pf_text *text, size_t *pos);
int pf_text_redo(pf_text *text, size_t *pos);
size_t pf_text_redo_branches(const pf_text *text);
int pf_text_select_redo_branch(pf_text *text, size_t index); /* -1 if out of range */

/* Modified means the undo history has moved off the state of the last pf_text_mark_saved (or
 * creation); undoing back to that state makes the text unmodified again. */
void pf_text_mark_saved(pf_text *text);
int pf_text_modified(const pf_text *text);

/* The text's properties (pf_props.h), kept in step with edits, undo and redo. Undo restores
 * text but not the properties it had: re-highlighting covers that. Main thread. */
struct pf_props *pf_text_props(pf_text *text);

/* Current snapshot, borrowed: valid until the next edit or pf_text_free. Retain to keep it. */
const pf_text_snapshot *pf_text_current(const pf_text *text);

const pf_text_snapshot *pf_text_snapshot_retain(const pf_text_snapshot *snap);
void pf_text_snapshot_release(const pf_text_snapshot *snap);

size_t pf_text_bytes(const pf_text_snapshot *snap);
size_t pf_text_chars(const pf_text_snapshot *snap);
/* Number of lines: newlines + 1 (an empty text has one empty line). */
size_t pf_text_lines(const pf_text_snapshot *snap);

/* Position conversions, clamped to the text. A byte offset inside a character maps to that
 * character. */
size_t pf_text_char_to_byte(const pf_text_snapshot *snap, size_t pos);
size_t pf_text_byte_to_char(const pf_text_snapshot *snap, size_t byte);

/* Character position where 0-based LINE starts (pf_text_chars for LINE past the end), and the
 * 0-based line containing POS. */
size_t pf_text_line_start(const pf_text_snapshot *snap, size_t line);
size_t pf_text_line_of(const pf_text_snapshot *snap, size_t pos);

/* Copies the bytes of characters [START, END) into OUT (at most CAP bytes, no terminator) and
 * returns the full byte length of the range, so a call with CAP 0 sizes the buffer. */
size_t pf_text_copy(const pf_text_snapshot *snap, size_t start, size_t end, char *out, size_t cap);

/* Calls FN with each contiguous byte chunk of characters [START, END), in order, until FN
 * returns nonzero (which is returned). Chunks point into shared storage and stay valid while
 * the snapshot is retained. */
typedef int (*pf_text_chunk_fn)(const char *bytes, size_t len, void *ctx);
int pf_text_for_each_chunk(const pf_text_snapshot *snap, size_t start, size_t end,
                           pf_text_chunk_fn fn, void *ctx);

/* Diagnostics for tests and benchmarks. */
size_t pf_text_piece_count(const pf_text_snapshot *snap);
size_t pf_text_depth(const pf_text_snapshot *snap);

#endif
