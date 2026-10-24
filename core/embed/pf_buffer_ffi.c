#include "pf_buffer_ffi.h"

#include "pf_text.h"

enum { INVALID = -2 };

#define TEXT_OR(buf, fail)                                                                         \
    pf_text *t = pf_handle_get((buf), PF_HANDLE_TEXT);                                             \
    if (!t) {                                                                                      \
        return (fail);                                                                             \
    }

pf_handle pf_buf_new(const char *bytes, size_t len) {
    pf_text *t = pf_text_new(bytes, len);
    if (!t) {
        return 0;
    }
    pf_handle h = pf_handle_new(PF_HANDLE_TEXT, t);
    if (!h) {
        pf_text_free(t);
    }
    return h;
}

int pf_buf_free(pf_handle buf) {
    pf_text *t = pf_handle_free(buf, PF_HANDLE_TEXT);
    if (!t) {
        return INVALID;
    }
    pf_text_free(t);
    return 0;
}

int64_t pf_buf_chars(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_chars(pf_text_current(t));
}

int64_t pf_buf_bytes(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_bytes(pf_text_current(t));
}

int64_t pf_buf_lines(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_lines(pf_text_current(t));
}

int pf_buf_insert(pf_handle buf, size_t pos, const char *bytes, size_t len) {
    TEXT_OR(buf, INVALID);
    return pf_text_insert(t, pos, bytes, len);
}

int pf_buf_delete(pf_handle buf, size_t start, size_t end) {
    TEXT_OR(buf, INVALID);
    pf_text_delete(t, start, end);
    return 0;
}

int64_t pf_buf_range_bytes(pf_handle buf, size_t start, size_t end) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_copy(pf_text_current(t), start, end, NULL, 0);
}

int64_t pf_buf_copy(pf_handle buf, size_t start, size_t end, char *out, size_t cap) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_copy(pf_text_current(t), start, end, out, cap);
}

int64_t pf_buf_char_at(pf_handle buf, size_t pos) {
    TEXT_OR(buf, INVALID);
    unsigned char u[4];
    size_t n = pf_text_copy(pf_text_current(t), pos, pos + 1, (char *)u, sizeof u);
    if (n == 0) {
        return -1;
    }
    if (n == 1) {
        return u[0] < 0x80 ? u[0] : 0xFFFD;
    }
    /* A multi-byte unit is always well formed (see pf_utf8_unit_len). */
    uint32_t cp = u[0] & (0x7F >> n);
    for (size_t i = 1; i < n; i++) {
        cp = cp << 6 | (u[i] & 0x3F);
    }
    return cp;
}

int64_t pf_buf_line_start(pf_handle buf, size_t line) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_line_start(pf_text_current(t), line);
}

int64_t pf_buf_line_of(pf_handle buf, size_t pos) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_line_of(pf_text_current(t), pos);
}

int64_t pf_buf_char_to_byte(pf_handle buf, size_t pos) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_char_to_byte(pf_text_current(t), pos);
}

int64_t pf_buf_byte_to_char(pf_handle buf, size_t byte) {
    TEXT_OR(buf, INVALID);
    return (int64_t)pf_text_byte_to_char(pf_text_current(t), byte);
}

uint32_t pf_buf_marker_new(pf_handle buf, size_t pos, int advances) {
    TEXT_OR(buf, 0);
    return pf_marker_new(t, pos, advances);
}

int pf_buf_marker_free(pf_handle buf, uint32_t marker) {
    TEXT_OR(buf, INVALID);
    pf_marker_free(t, marker);
    return 0;
}

int64_t pf_buf_marker_pos(pf_handle buf, uint32_t marker) {
    TEXT_OR(buf, INVALID);
    size_t pos = pf_marker_pos(t, marker);
    return pos == SIZE_MAX ? -1 : (int64_t)pos;
}

int pf_buf_marker_set(pf_handle buf, uint32_t marker, size_t pos) {
    TEXT_OR(buf, INVALID);
    return pf_marker_set(t, marker, pos);
}

int pf_buf_undo_boundary(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    pf_text_undo_boundary(t);
    return 0;
}

int pf_buf_set_undo(pf_handle buf, int enabled) {
    TEXT_OR(buf, INVALID);
    pf_text_set_undo(t, enabled);
    return 0;
}

int64_t pf_buf_undo(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    size_t pos;
    return pf_text_undo(t, &pos) ? (int64_t)pos : -1;
}

int64_t pf_buf_redo(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    size_t pos;
    return pf_text_redo(t, &pos) ? (int64_t)pos : -1;
}

int pf_buf_modified(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    return pf_text_modified(t);
}

int pf_buf_mark_saved(pf_handle buf) {
    TEXT_OR(buf, INVALID);
    pf_text_mark_saved(t);
    return 0;
}
