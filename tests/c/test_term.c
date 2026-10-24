#include <stdlib.h>
#include <string.h>

#include "pf_term.h"
#include "pf_test.h"

static void feed(pf_term *t, const char *s) { pf_term_feed(t, s, strlen(s)); }

static char row_text[256];
static const char *row(const pf_term *t, int r) {
    size_t n = 0;
    for (int c = 0; c < pf_term_cols(t); c++) {
        pf_term_cell cell;
        pf_term_cell_get(t, r, c, &cell);
        if (cell.width == 0) {
            continue;
        }
        n += (size_t)snprintf(row_text + n, sizeof row_text - n, "%c", cell.cps[0] && cell.cps[0] < 128 ? (char)cell.cps[0] : cell.cps[0] ? '?' : ' ');
    }
    while (n > 0 && row_text[n - 1] == ' ') {
        n--;
    }
    row_text[n] = 0;
    return row_text;
}

static char out_text[256];
static const char *output(pf_term *t) {
    size_t n = pf_term_output(t, out_text, sizeof out_text - 1);
    out_text[n] = 0;
    return out_text;
}

static uint32_t ansi[16] = {0x000000, 0xCC0000, 0x00CC00, 0xCCCC00, 0x0000CC, 0xCC00CC, 0x00CCCC, 0xCCCCCC,
                            0x555555, 0xFF0000, 0x00FF00, 0xFFFF00, 0x0000FF, 0xFF00FF, 0x00FFFF, 0xFFFFFF};

int main(void) {
    pf_term *t = pf_term_new(5, 20, 100);
    pf_term_set_colors(t, 0xEEEEEE, 0x101010, ansi);
    uint64_t v0 = pf_term_version(t);

    /* text and the cursor */
    feed(t, "hello");
    PF_CHECK_EQ_STR(row(t, 0), "hello");
    PF_CHECK(pf_term_version(t) > v0);
    int r, c, vis, shape, blink;
    pf_term_cursor(t, &r, &c, &vis, &shape, &blink);
    PF_CHECK(r == 0 && c == 5 && vis == 1 && shape == 1);
    feed(t, "\r\nworld");
    PF_CHECK_EQ_STR(row(t, 1), "world");
    pf_term_cursor(t, &r, &c, &vis, &shape, &blink);
    PF_CHECK(r == 1 && c == 5);

    /* colors and attributes */
    pf_term_cell cell;
    pf_term_cell_get(t, 0, 0, &cell);
    PF_CHECK(cell.fg == 0xEEEEEEFF && cell.bg == 0x101010FF && cell.bg_default == 1);
    feed(t, "\x1b[2J\x1b[H\x1b[31mR\x1b[1;3;4mB\x1b[0;7mV\x1b[0;48;2;1;2;3;38;5;196mT\x1b[0m");
    pf_term_cell_get(t, 0, 0, &cell);
    PF_CHECK(cell.fg == 0xCC0000FF && !cell.bold);
    pf_term_cell_get(t, 0, 1, &cell);
    PF_CHECK(cell.bold && cell.italic && cell.underline == 1 && cell.fg == 0xCC0000FF);
    pf_term_cell_get(t, 0, 2, &cell);
    PF_CHECK(cell.fg == 0x101010FF && cell.bg == 0xEEEEEEFF && cell.bg_default == 0); /* reverse video */
    pf_term_cell_get(t, 0, 3, &cell);
    PF_CHECK(cell.bg == 0x010203FF && cell.bg_default == 0 && cell.fg == 0xFF0000FF); /* truecolor and 256-color */

    /* wide characters take two cells */
    feed(t, "\x1b[2J\x1b[H\xe6\x97\xa5x");
    pf_term_cell_get(t, 0, 0, &cell);
    PF_CHECK(cell.cps[0] == 0x65E5 && cell.width == 2);
    pf_term_cell_get(t, 0, 1, &cell);
    PF_CHECK(cell.width == 0);
    pf_term_cell_get(t, 0, 2, &cell);
    PF_CHECK(cell.cps[0] == 'x');

    /* scrollback: lines that scroll off the top are kept and can be looked at */
    feed(t, "\x1b[2J\x1b[H");
    for (int i = 1; i <= 8; i++) {
        char line[16];
        snprintf(line, sizeof line, "line%d\r\n", i);
        feed(t, line);
    }
    PF_CHECK(pf_term_scrollback_lines(t) == 4);
    PF_CHECK_EQ_STR(row(t, 0), "line5");
    PF_CHECK(pf_term_scroll_view(t, 2) == 2);
    PF_CHECK_EQ_STR(row(t, 0), "line3");
    PF_CHECK_EQ_STR(row(t, 2), "line5");
    pf_term_cursor(t, &r, &c, &vis, &shape, &blink);
    PF_CHECK(vis == 0); /* hidden while looking back */
    PF_CHECK(pf_term_scroll_view(t, 100) == 4);
    PF_CHECK_EQ_STR(row(t, 0), "line1");
    PF_CHECK(pf_term_scroll_view(t, -100) == 0);
    pf_term_scroll_view(t, 3);
    feed(t, "x");
    PF_CHECK(pf_term_view_offset(t) == 0); /* output returns to the live screen */

    /* text dump: scrollback then screen, trailing blanks trimmed */
    char dump[512];
    size_t n = pf_term_text_dump(t, dump, sizeof dump - 1);
    dump[n] = 0;
    PF_CHECK(strncmp(dump, "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nx", 48) == 0);

    /* resize keeps the cursor line and the history */
    pf_term_resize(t, 3, 10);
    PF_CHECK(pf_term_rows(t) == 3 && pf_term_cols(t) == 10);
    pf_term_resize(t, 6, 30);
    PF_CHECK(pf_term_rows(t) == 6 && pf_term_cols(t) == 30);

    /* what is sent to the program */
    pf_term_output(t, out_text, sizeof out_text);
    PF_CHECK(pf_term_key(t, "a", 1) == 0);
    PF_CHECK_EQ_STR(output(t), "a");
    pf_term_key(t, "C-a", 3);
    PF_CHECK_EQ_STR(output(t), "\x01");
    pf_term_key(t, "C-c", 3);
    PF_CHECK_EQ_STR(output(t), "\x03");
    pf_term_key(t, "M-x", 3);
    PF_CHECK_EQ_STR(output(t), "\x1b" "x");
    pf_term_key(t, "RET", 3);
    PF_CHECK_EQ_STR(output(t), "\r");
    pf_term_key(t, "TAB", 3);
    PF_CHECK_EQ_STR(output(t), "\t");
    pf_term_key(t, "DEL", 3);
    PF_CHECK_EQ_STR(output(t), "\x7f");
    pf_term_key(t, "ESC", 3);
    PF_CHECK_EQ_STR(output(t), "\x1b");
    pf_term_key(t, "SPC", 3);
    PF_CHECK_EQ_STR(output(t), " ");
    pf_term_key(t, "C-SPC", 5);
    PF_CHECK_EQ_STR(output(t), "\0");
    pf_term_key(t, "<up>", 4);
    PF_CHECK_EQ_STR(output(t), "\x1b[A");
    pf_term_key(t, "<f1>", 4);
    PF_CHECK_EQ_STR(output(t), "\x1bOP");
    pf_term_key(t, "<deletechar>", 12);
    PF_CHECK_EQ_STR(output(t), "\x1b[3~");
    pf_term_key(t, "S-<left>", 8);
    PF_CHECK_EQ_STR(output(t), "\x1b[1;2D");
    pf_term_key(t, "<backtab>", 9);
    PF_CHECK_EQ_STR(output(t), "\x1b[Z");
    pf_term_key(t, "\xc3\xa9", 2); /* é */
    PF_CHECK_EQ_STR(output(t), "\xc3\xa9");
    PF_CHECK(pf_term_key(t, "<nonsense>", 10) == -1);
    PF_CHECK(pf_term_key(t, "", 0) == -1);
    pf_term_text(t, "h\xc3\xa9llo", 6);
    PF_CHECK_EQ_STR(output(t), "h\xc3\xa9llo");

    /* application cursor keys change the encoding */
    feed(t, "\x1b[?1h");
    pf_term_key(t, "<up>", 4);
    PF_CHECK_EQ_STR(output(t), "\x1bOA");
    feed(t, "\x1b[?1l");

    /* the program asks, the terminal answers (device attributes) */
    feed(t, "\x1b[c");
    PF_CHECK(strncmp(output(t), "\x1b[?", 3) == 0);

    /* bracketed paste only when asked for */
    pf_term_paste(t, "hi", 2);
    PF_CHECK_EQ_STR(output(t), "hi");
    feed(t, "\x1b[?2004h");
    pf_term_paste(t, "hi", 2);
    PF_CHECK_EQ_STR(output(t), "\x1b[200~hi\x1b[201~");

    /* title, bell, mouse, alternate screen */
    feed(t, "\x1b]0;my title\x07");
    char title[64];
    size_t tn = pf_term_title(t, title, sizeof title - 1);
    title[tn] = 0;
    PF_CHECK_EQ_STR(title, "my title");
    uint64_t bells = pf_term_bell_count(t);
    feed(t, "\a");
    PF_CHECK(pf_term_bell_count(t) == bells + 1);
    PF_CHECK(pf_term_mouse_mode(t) == 0);
    feed(t, "\x1b[?1002h");
    PF_CHECK(pf_term_mouse_mode(t) == 2);
    int lines = pf_term_scrollback_lines(t);
    feed(t, "\x1b[?1049h");
    PF_CHECK(pf_term_alt_screen(t) == 1);
    feed(t, "a\r\nb\r\nc\r\nd\r\ne\r\nf\r\ng\r\nh\r\n");
    PF_CHECK(pf_term_scrollback_lines(t) == lines); /* no history from the alternate screen */
    feed(t, "\x1b[?1049l");
    PF_CHECK(pf_term_alt_screen(t) == 0);

    /* colors can change after the fact */
    uint32_t light[16];
    memcpy(light, ansi, sizeof light);
    light[1] = 0x112233;
    pf_term_set_colors(t, 0x000000, 0xFFFFFF, light);
    feed(t, "\x1b[2J\x1b[H\x1b[31mR");
    pf_term_cell_get(t, 0, 0, &cell);
    PF_CHECK(cell.fg == 0x112233FF);
    pf_term_cell_get(t, 0, 5, &cell);
    PF_CHECK(cell.bg == 0xFFFFFFFF && cell.bg_default);

    /* out of range cells are blank */
    pf_term_cell_get(t, 100, 100, &cell);
    PF_CHECK(cell.cps[0] == 0 && cell.width == 1);

    pf_term_free(t);

    /* a terminal without scrollback */
    pf_term *s = pf_term_new(2, 10, 0);
    feed(s, "1\r\n2\r\n3\r\n4");
    PF_CHECK(pf_term_scrollback_lines(s) == 0);
    pf_term_free(s);

    return pf_test_failures ? 1 : 0;
}
