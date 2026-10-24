#include "pf_term.h"

#include <stdlib.h>
#include <string.h>

#include "vterm.h"

/* A scrolled-off line, kept compactly: trailing blank cells are dropped. */
typedef struct sb_cell {
    uint32_t cp;
    VTermColor fg, bg;
    uint8_t width;
    uint8_t bold : 1, italic : 1, strike : 1, blink : 1, reverse : 1, conceal : 1;
    uint8_t underline : 2;
} sb_cell;

typedef struct sb_line {
    sb_cell *cells;
    int n;
} sb_line;

struct pf_term {
    VTerm *vt;
    VTermScreen *screen;
    VTermState *state;
    int rows, cols;
    uint64_t version;
    uint32_t default_fg, default_bg; /* 0xRRGGBB */

    sb_line *ring; /* oldest first at ring_start */
    int ring_cap, ring_start, ring_len;
    int view_offset;

    unsigned char *out;
    size_t out_len, out_cap;

    int cursor_row, cursor_col, cursor_visible, cursor_shape, cursor_blink;
    char *title;
    size_t title_len, title_cap;
    uint64_t bells;
    int alt_screen, mouse_mode;
};

/* Decodes one character at S (N > 0 bytes); returns its length, or 0 if it is not well-formed. */
static size_t utf8_decode(const char *s, size_t n, uint32_t *cp) {
    const unsigned char *u = (const unsigned char *)s;
    size_t len = u[0] < 0x80 ? 1 : (u[0] >> 5) == 6 ? 2 : (u[0] >> 4) == 14 ? 3 : (u[0] >> 3) == 30 ? 4 : 0;
    if (len == 0 || len > n) {
        return 0;
    }
    uint32_t c = len == 1 ? u[0] : u[0] & (0xFF >> (len + 1));
    for (size_t i = 1; i < len; i++) {
        if ((u[i] & 0xC0) != 0x80) {
            return 0;
        }
        c = (c << 6) | (u[i] & 0x3F);
    }
    *cp = c;
    return len;
}

static size_t utf8_encode(uint32_t cp, char out[4]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

static void *xrealloc(void *p, size_t n) {
    void *q = realloc(p, n);
    if (!q) {
        abort();
    }
    return q;
}

/* ---- scrollback ---- */

static void sb_free_line(sb_line *l) {
    free(l->cells);
    l->cells = NULL;
    l->n = 0;
}

static void sb_push(pf_term *t, int cols, const VTermScreenCell *cells) {
    if (t->ring_cap == 0 || t->alt_screen) {
        return;
    }
    int n = cols;
    while (n > 0 && cells[n - 1].chars[0] == 0 && VTERM_COLOR_IS_DEFAULT_BG(&cells[n - 1].bg) &&
           !cells[n - 1].attrs.reverse) {
        n--;
    }
    sb_line line = {NULL, n};
    if (n > 0) {
        line.cells = xrealloc(NULL, (size_t)n * sizeof *line.cells);
        for (int i = 0; i < n; i++) {
            const VTermScreenCell *c = &cells[i];
            line.cells[i] = (sb_cell){.cp = c->chars[0], .fg = c->fg, .bg = c->bg, .width = (uint8_t)c->width,
                                      .bold = c->attrs.bold, .italic = c->attrs.italic,
                                      .strike = c->attrs.strike, .blink = c->attrs.blink,
                                      .reverse = c->attrs.reverse, .conceal = c->attrs.conceal,
                                      .underline = c->attrs.underline};
        }
    }
    int slot;
    if (t->ring_len == t->ring_cap) {
        slot = t->ring_start;
        sb_free_line(&t->ring[slot]);
        t->ring_start = (t->ring_start + 1) % t->ring_cap;
    } else {
        slot = (t->ring_start + t->ring_len) % t->ring_cap;
        t->ring_len++;
    }
    t->ring[slot] = line;
    if (t->view_offset > 0) { /* keep looking at the same text */
        t->view_offset = t->view_offset < t->ring_len ? t->view_offset + 1 : t->ring_len;
    }
}

static sb_line *sb_at(const pf_term *t, int index) { /* 0 = oldest */
    return &t->ring[(t->ring_start + index) % t->ring_cap];
}

static void cell_from_sb(const sb_cell *s, VTermScreenCell *c) {
    memset(c, 0, sizeof *c);
    c->chars[0] = s->cp;
    c->width = (char)s->width;
    c->fg = s->fg;
    c->bg = s->bg;
    c->attrs.bold = s->bold;
    c->attrs.italic = s->italic;
    c->attrs.strike = s->strike;
    c->attrs.blink = s->blink;
    c->attrs.reverse = s->reverse;
    c->attrs.conceal = s->conceal;
    c->attrs.underline = s->underline;
}

/* ---- libvterm callbacks ---- */

static int cb_damage(VTermRect rect, void *user) {
    (void)rect;
    ((pf_term *)user)->version++;
    return 1;
}

static int cb_movecursor(VTermPos pos, VTermPos old, int visible, void *user) {
    (void)old;
    pf_term *t = user;
    t->cursor_row = pos.row;
    t->cursor_col = pos.col;
    t->cursor_visible = visible;
    t->version++;
    return 1;
}

static int cb_settermprop(VTermProp prop, VTermValue *val, void *user) {
    pf_term *t = user;
    switch (prop) {
    case VTERM_PROP_CURSORVISIBLE:
        t->cursor_visible = val->boolean;
        break;
    case VTERM_PROP_CURSORBLINK:
        t->cursor_blink = val->boolean;
        break;
    case VTERM_PROP_CURSORSHAPE:
        t->cursor_shape = val->number;
        break;
    case VTERM_PROP_ALTSCREEN:
        t->alt_screen = val->boolean;
        break;
    case VTERM_PROP_MOUSE:
        t->mouse_mode = val->number;
        break;
    case VTERM_PROP_TITLE: {
        if (val->string.initial) {
            t->title_len = 0;
        }
        size_t need = t->title_len + val->string.len + 1;
        if (need > t->title_cap) {
            t->title_cap = need * 2;
            t->title = xrealloc(t->title, t->title_cap);
        }
        memcpy(t->title + t->title_len, val->string.str, val->string.len);
        t->title_len += val->string.len;
        break;
    }
    default:
        break;
    }
    t->version++;
    return 1;
}

static int cb_bell(void *user) {
    pf_term *t = user;
    t->bells++;
    return 1;
}

static int cb_resize(int rows, int cols, void *user) {
    pf_term *t = user;
    t->rows = rows;
    t->cols = cols;
    t->version++;
    return 1;
}

static int cb_sb_pushline(int cols, const VTermScreenCell *cells, void *user) {
    sb_push(user, cols, cells);
    return 1;
}

static int cb_sb_popline(int cols, VTermScreenCell *cells, void *user) {
    pf_term *t = user;
    if (t->ring_len == 0) {
        return 0;
    }
    int slot = (t->ring_start + t->ring_len - 1) % t->ring_cap;
    sb_line *line = &t->ring[slot];
    for (int i = 0; i < cols; i++) {
        if (i < line->n) {
            cell_from_sb(&line->cells[i], &cells[i]);
        } else {
            memset(&cells[i], 0, sizeof cells[i]);
            cells[i].width = 1;
            cells[i].fg.type = VTERM_COLOR_DEFAULT_FG;
            cells[i].bg.type = VTERM_COLOR_DEFAULT_BG;
        }
    }
    sb_free_line(line);
    t->ring_len--;
    if (t->view_offset > t->ring_len) {
        t->view_offset = t->ring_len;
    }
    return 1;
}

static int cb_sb_clear(void *user) {
    pf_term *t = user;
    for (int i = 0; i < t->ring_len; i++) {
        sb_free_line(sb_at(t, i));
    }
    t->ring_len = 0;
    t->ring_start = 0;
    t->view_offset = 0;
    t->version++;
    return 1;
}

static const VTermScreenCallbacks screen_callbacks = {
    .damage = cb_damage,
    .movecursor = cb_movecursor,
    .settermprop = cb_settermprop,
    .bell = cb_bell,
    .resize = cb_resize,
    .sb_pushline = cb_sb_pushline,
    .sb_popline = cb_sb_popline,
    .sb_clear = cb_sb_clear,
};

static void on_output(const char *bytes, size_t len, void *user) {
    pf_term *t = user;
    if (t->out_len + len > t->out_cap) {
        t->out_cap = (t->out_len + len) * 2;
        t->out = xrealloc(t->out, t->out_cap);
    }
    memcpy(t->out + t->out_len, bytes, len);
    t->out_len += len;
}

/* ---- lifecycle ---- */

static VTermColor rgb(uint32_t c) {
    VTermColor v;
    vterm_color_rgb(&v, (uint8_t)(c >> 16), (uint8_t)(c >> 8), (uint8_t)c);
    return v;
}

pf_term *pf_term_new(int rows, int cols, int scrollback) {
    if (rows < 1) {
        rows = 1;
    }
    if (cols < 1) {
        cols = 1;
    }
    pf_term *t = calloc(1, sizeof *t);
    if (!t) {
        abort();
    }
    t->rows = rows;
    t->cols = cols;
    t->vt = vterm_new(rows, cols);
    vterm_set_utf8(t->vt, 1);
    vterm_output_set_callback(t->vt, on_output, t);
    t->state = vterm_obtain_state(t->vt);
    t->screen = vterm_obtain_screen(t->vt);
    vterm_screen_enable_altscreen(t->screen, 1);
    vterm_screen_set_callbacks(t->screen, &screen_callbacks, t);
    vterm_screen_set_damage_merge(t->screen, VTERM_DAMAGE_SCREEN);
    t->ring_cap = scrollback > 0 ? scrollback : 0;
    if (t->ring_cap) {
        t->ring = calloc((size_t)t->ring_cap, sizeof *t->ring);
    }
    t->cursor_visible = 1;
    t->cursor_shape = VTERM_PROP_CURSORSHAPE_BLOCK;
    t->default_fg = 0xDDDDDD;
    t->default_bg = 0x000000;
    VTermColor fg = rgb(t->default_fg), bg = rgb(t->default_bg);
    vterm_screen_set_default_colors(t->screen, &fg, &bg);
    vterm_screen_reset(t->screen, 1);
    return t;
}

void pf_term_free(pf_term *t) {
    if (!t) {
        return;
    }
    for (int i = 0; i < t->ring_len; i++) {
        sb_free_line(sb_at(t, i));
    }
    free(t->ring);
    vterm_free(t->vt);
    free(t->out);
    free(t->title);
    free(t);
}

int pf_term_rows(const pf_term *t) { return t->rows; }
int pf_term_cols(const pf_term *t) { return t->cols; }
uint64_t pf_term_version(const pf_term *t) { return t->version; }

void pf_term_resize(pf_term *t, int rows, int cols) {
    if (rows < 1) {
        rows = 1;
    }
    if (cols < 1) {
        cols = 1;
    }
    if (rows == t->rows && cols == t->cols) {
        return;
    }
    vterm_set_size(t->vt, rows, cols);
    vterm_screen_flush_damage(t->screen);
    t->rows = rows;
    t->cols = cols;
    t->version++;
}

void pf_term_feed(pf_term *t, const void *bytes, size_t len) {
    if (len == 0) {
        return;
    }
    if (t->view_offset) {
        t->view_offset = 0;
    }
    vterm_input_write(t->vt, bytes, len);
    vterm_screen_flush_damage(t->screen);
    t->version++;
}

size_t pf_term_output(pf_term *t, void *buf, size_t cap) {
    size_t n = t->out_len < cap ? t->out_len : cap;
    if (n == 0) {
        return 0;
    }
    memcpy(buf, t->out, n);
    memmove(t->out, t->out + n, t->out_len - n);
    t->out_len -= n;
    return n;
}

void pf_term_set_colors(pf_term *t, uint32_t fg, uint32_t bg, const uint32_t ansi[16]) {
    t->default_fg = fg & 0xFFFFFF;
    t->default_bg = bg & 0xFFFFFF;
    VTermColor f = rgb(t->default_fg), b = rgb(t->default_bg);
    vterm_screen_set_default_colors(t->screen, &f, &b);
    for (int i = 0; i < 16; i++) {
        VTermColor c = rgb(ansi[i]);
        vterm_state_set_palette_color(t->state, i, &c);
    }
    t->version++;
}

/* ---- input ---- */

static int named_key(const char *name, size_t n, VTermKey *key) {
    static const struct {
        const char *name;
        VTermKey key;
    } table[] = {{"up", VTERM_KEY_UP},       {"down", VTERM_KEY_DOWN},     {"left", VTERM_KEY_LEFT},
                 {"right", VTERM_KEY_RIGHT}, {"home", VTERM_KEY_HOME},     {"end", VTERM_KEY_END},
                 {"prior", VTERM_KEY_PAGEUP}, {"next", VTERM_KEY_PAGEDOWN}, {"deletechar", VTERM_KEY_DEL},
                 {"insert", VTERM_KEY_INS},  {"backtab", VTERM_KEY_TAB},   {"return", VTERM_KEY_ENTER},
                 {"escape", VTERM_KEY_ESCAPE}, {"backspace", VTERM_KEY_BACKSPACE}};
    for (size_t i = 0; i < sizeof table / sizeof table[0]; i++) {
        if (strlen(table[i].name) == n && memcmp(table[i].name, name, n) == 0) {
            *key = table[i].key;
            return 1;
        }
    }
    if (n >= 2 && n <= 3 && name[0] == 'f') {
        int num = atoi(name + 1);
        if (num >= 1 && num <= 24) {
            *key = (VTermKey)VTERM_KEY_FUNCTION(num);
            return 1;
        }
    }
    return 0;
}

int pf_term_key(pf_term *t, const char *key, size_t len) {
    VTermModifier mod = VTERM_MOD_NONE;
    /* modifier prefixes: C- M- S- (s- has no terminal meaning and is ignored) */
    while (len > 2 && key[1] == '-' && (key[0] == 'C' || key[0] == 'M' || key[0] == 'S' || key[0] == 's')) {
        if (key[0] == 'C') {
            mod |= VTERM_MOD_CTRL;
        } else if (key[0] == 'M') {
            mod |= VTERM_MOD_ALT;
        } else if (key[0] == 'S') {
            mod |= VTERM_MOD_SHIFT;
        }
        key += 2;
        len -= 2;
    }
    if (len == 0) {
        return -1;
    }
    VTermKey vk;
    if (len > 2 && key[0] == '<' && key[len - 1] == '>') {
        if (!named_key(key + 1, len - 2, &vk)) {
            return -1;
        }
        if (vk == VTERM_KEY_TAB && memcmp(key + 1, "backtab", 7) == 0) {
            mod |= VTERM_MOD_SHIFT;
        }
        vterm_keyboard_key(t->vt, vk, mod);
    } else if (len == 3 && memcmp(key, "RET", 3) == 0) {
        vterm_keyboard_key(t->vt, VTERM_KEY_ENTER, mod);
    } else if (len == 3 && memcmp(key, "TAB", 3) == 0) {
        vterm_keyboard_key(t->vt, VTERM_KEY_TAB, mod);
    } else if (len == 3 && memcmp(key, "DEL", 3) == 0) {
        vterm_keyboard_key(t->vt, VTERM_KEY_BACKSPACE, mod);
    } else if (len == 3 && memcmp(key, "ESC", 3) == 0) {
        vterm_keyboard_key(t->vt, VTERM_KEY_ESCAPE, mod);
    } else if (len == 3 && memcmp(key, "SPC", 3) == 0) {
        vterm_keyboard_unichar(t->vt, ' ', mod);
    } else {
        uint32_t cp;
        size_t used = utf8_decode(key, len, &cp);
        if (used == 0 || used != len) {
            return -1;
        }
        vterm_keyboard_unichar(t->vt, cp, mod);
    }
    t->view_offset = 0;
    t->version++;
    return 0;
}

void pf_term_text(pf_term *t, const char *utf8, size_t len) {
    size_t i = 0;
    while (i < len) {
        uint32_t cp;
        size_t used = utf8_decode(utf8 + i, len - i, &cp);
        if (used == 0) {
            break;
        }
        vterm_keyboard_unichar(t->vt, cp, VTERM_MOD_NONE);
        i += used;
    }
    t->view_offset = 0;
    t->version++;
}

void pf_term_paste(pf_term *t, const char *utf8, size_t len) {
    vterm_keyboard_start_paste(t->vt);
    on_output(utf8, len, t); /* pasted text is sent as it is, not as key presses */
    vterm_keyboard_end_paste(t->vt);
}

/* ---- looking ---- */

static uint32_t resolve(const pf_term *t, VTermColor c) {
    vterm_screen_convert_color_to_rgb(t->screen, &c);
    return ((uint32_t)c.rgb.red << 24) | ((uint32_t)c.rgb.green << 16) | ((uint32_t)c.rgb.blue << 8) | 0xFF;
}

static void fill_cell(const pf_term *t, const VTermScreenCell *vc, pf_term_cell *out) {
    memset(out, 0, sizeof *out);
    for (int i = 0; i < PF_TERM_MAX_CPS && i < VTERM_MAX_CHARS_PER_CELL; i++) {
        out->cps[i] = vc->chars[i];
        if (vc->chars[i] == 0) {
            break;
        }
    }
    out->width = (uint8_t)vc->width;
    if (vc->chars[0] == (uint32_t)-1) { /* the right half of a wide character */
        out->width = 0;
        out->cps[0] = 0;
    }
    VTermColor fg = vc->fg, bg = vc->bg;
    int bg_default = VTERM_COLOR_IS_DEFAULT_BG(&bg);
    if (vc->attrs.reverse) {
        VTermColor tmp = fg;
        fg = bg;
        bg = tmp;
        bg_default = 0;
    }
    out->fg = resolve(t, fg);
    out->bg = resolve(t, bg);
    out->bg_default = (uint8_t)bg_default;
    out->bold = vc->attrs.bold;
    out->italic = vc->attrs.italic;
    out->underline = vc->attrs.underline;
    out->strike = vc->attrs.strike;
    out->blink = vc->attrs.blink;
    out->conceal = vc->attrs.conceal;
}

void pf_term_cell_get(const pf_term *t, int row, int col, pf_term_cell *out) {
    VTermScreenCell vc;
    memset(&vc, 0, sizeof vc);
    vc.width = 1;
    vc.fg.type = VTERM_COLOR_DEFAULT_FG;
    vc.bg.type = VTERM_COLOR_DEFAULT_BG;
    vc.fg.rgb.red = (uint8_t)(t->default_fg >> 16);
    vc.fg.rgb.green = (uint8_t)(t->default_fg >> 8);
    vc.fg.rgb.blue = (uint8_t)t->default_fg;
    vc.bg.rgb.red = (uint8_t)(t->default_bg >> 16);
    vc.bg.rgb.green = (uint8_t)(t->default_bg >> 8);
    vc.bg.rgb.blue = (uint8_t)t->default_bg;
    if (row >= 0 && row < t->rows && col >= 0 && col < t->cols) {
        int live_row = row - t->view_offset;
        if (live_row >= 0) {
            vterm_screen_get_cell(t->screen, (VTermPos){live_row, col}, &vc);
        } else {
            int index = t->ring_len + live_row; /* live_row < 0: that far back */
            if (index >= 0 && index < t->ring_len) {
                sb_line *line = sb_at(t, index);
                if (col < line->n) {
                    cell_from_sb(&line->cells[col], &vc);
                }
            }
        }
    }
    fill_cell(t, &vc, out);
}

int pf_term_scroll_view(pf_term *t, int lines) {
    int next = t->view_offset + lines;
    if (next < 0) {
        next = 0;
    }
    if (next > t->ring_len) {
        next = t->ring_len;
    }
    if (next != t->view_offset) {
        t->view_offset = next;
        t->version++;
    }
    return t->view_offset;
}

int pf_term_view_offset(const pf_term *t) { return t->view_offset; }
int pf_term_scrollback_lines(const pf_term *t) { return t->ring_len; }

void pf_term_cursor(const pf_term *t, int *row, int *col, int *visible, int *shape, int *blink) {
    if (row) {
        *row = t->cursor_row + t->view_offset;
    }
    if (col) {
        *col = t->cursor_col;
    }
    if (visible) {
        *visible = t->cursor_visible && t->view_offset == 0;
    }
    if (shape) {
        *shape = t->cursor_shape;
    }
    if (blink) {
        *blink = t->cursor_blink;
    }
}

size_t pf_term_title(const pf_term *t, char *buf, size_t cap) {
    size_t n = t->title_len < cap ? t->title_len : cap;
    if (n) {
        memcpy(buf, t->title, n);
    }
    return t->title_len;
}

uint64_t pf_term_bell_count(const pf_term *t) { return t->bells; }
int pf_term_alt_screen(const pf_term *t) { return t->alt_screen; }
int pf_term_mouse_mode(const pf_term *t) { return t->mouse_mode; }

/* ---- text ---- */

typedef struct dump {
    char *buf;
    size_t cap, len;
} dump;

static void dump_put(dump *d, const char *s, size_t n) {
    if (d->len < d->cap) {
        size_t room = d->cap - d->len;
        memcpy(d->buf + d->len, s, n < room ? n : room);
    }
    d->len += n;
}

static void dump_cp(dump *d, uint32_t cp) {
    char tmp[4];
    size_t n = utf8_encode(cp, tmp);
    dump_put(d, tmp, n);
}

size_t pf_term_text_dump(const pf_term *t, char *buf, size_t cap) {
    dump d = {buf, cap, 0};
    for (int i = 0; i < t->ring_len; i++) {
        sb_line *line = sb_at(t, i);
        int end = line->n;
        while (end > 0 && line->cells[end - 1].cp == 0) {
            end--;
        }
        for (int c = 0; c < end; c++) {
            if (line->cells[c].width == 0) {
                continue;
            }
            dump_cp(&d, line->cells[c].cp ? line->cells[c].cp : ' ');
        }
        dump_put(&d, "\n", 1);
    }
    int last = t->rows - 1; /* trailing blank rows are not part of the text */
    for (; last >= 0; last--) {
        int blank = 1;
        for (int c = 0; c < t->cols && blank; c++) {
            VTermScreenCell vc;
            vterm_screen_get_cell(t->screen, (VTermPos){last, c}, &vc);
            blank = vc.chars[0] == 0;
        }
        if (!blank) {
            break;
        }
    }
    for (int r = 0; r <= last; r++) {
        int end = t->cols;
        VTermScreenCell vc;
        while (end > 0) {
            vterm_screen_get_cell(t->screen, (VTermPos){r, end - 1}, &vc);
            if (vc.chars[0] != 0) {
                break;
            }
            end--;
        }
        for (int c = 0; c < end; c++) {
            vterm_screen_get_cell(t->screen, (VTermPos){r, c}, &vc);
            if (vc.width == 0 || (vc.chars[0] == (uint32_t)-1)) {
                continue;
            }
            if (vc.chars[0] == 0) {
                dump_put(&d, " ", 1);
            } else {
                for (int k = 0; k < VTERM_MAX_CHARS_PER_CELL && vc.chars[k]; k++) {
                    dump_cp(&d, vc.chars[k]);
                }
            }
        }
        if (r < last) {
            dump_put(&d, "\n", 1);
        }
    }
    return d.len;
}
