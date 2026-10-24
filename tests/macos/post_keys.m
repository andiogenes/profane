/* post_keys PID TOKEN... — sends keyboard events to one process only (CGEventPostToPid), so
 * tests never type into whatever app happens to be frontmost. Needs Accessibility permission.
 *
 * Tokens: "text:STRING" types STRING one composed character per event; "raw16:HEX" sends a
 * single UTF-16 code unit (e.g. an unpaired surrogate); "sleep:MS" pauses; otherwise an Emacs-style key such as
 * "a", "C-a", "M-<", "C-/", "RET", "DEL", "TAB", "<left>", "<up>". */

#import <ApplicationServices/ApplicationServices.h>
#import <Foundation/Foundation.h>

#include <stdlib.h>
#include <string.h>
#include <unistd.h>

typedef struct key {
    const char *name;
    CGKeyCode code;
    int shift;
} key;

/* ANSI layout virtual key codes. */
static const key keys[] = {
    {"a", 0, 0},  {"s", 1, 0},  {"d", 2, 0},  {"f", 3, 0},  {"h", 4, 0},  {"g", 5, 0},
    {"z", 6, 0},  {"x", 7, 0},  {"c", 8, 0},  {"v", 9, 0},  {"b", 11, 0}, {"q", 12, 0},
    {"w", 13, 0}, {"e", 14, 0}, {"r", 15, 0}, {"y", 16, 0}, {"t", 17, 0}, {"o", 31, 0},
    {"u", 32, 0}, {"i", 34, 0}, {"p", 35, 0}, {"l", 37, 0}, {"j", 38, 0}, {"k", 40, 0},
    {"n", 45, 0}, {"m", 46, 0}, {"/", 44, 0}, {"?", 44, 1}, {"-", 27, 0}, {"_", 27, 1},
    {"=", 24, 0}, {"+", 24, 1}, {"0", 29, 0}, {"1", 18, 0}, {"2", 19, 0}, {"3", 20, 0}, {",", 43, 0}, {"<", 43, 1}, {".", 47, 0}, {">", 47, 1}, {"RET", 36, 0}, {"TAB", 48, 0},
    {"DEL", 51, 0}, {"ESC", 53, 0}, {"SPC", 49, 0}, {"<left>", 123, 0}, {"<right>", 124, 0},
    {"<down>", 125, 0}, {"<up>", 126, 0}, {"<home>", 115, 0}, {"<end>", 119, 0},
};

static void post(pid_t pid, CGKeyCode code, CGEventFlags flags, const UniChar *text, size_t n) {
    for (int down = 1; down >= 0; down--) {
        CGEventRef e = CGEventCreateKeyboardEvent(NULL, code, down);
        CGEventSetFlags(e, flags);
        if (text) {
            CGEventKeyboardSetUnicodeString(e, (UniCharCount)n, text);
        }
        CGEventPostToPid(pid, e);
        CFRelease(e);
        usleep(2000);
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: post_keys PID TOKEN...\n");
        return 2;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    @autoreleasepool {
        for (int i = 2; i < argc; i++) {
            const char *tok = argv[i];
            if (strncmp(tok, "text:", 5) == 0) {
                NSString *s = @(tok + 5);
                for (NSUInteger j = 0; j < s.length;) {
                    NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:j];
                    UniChar buf[16];
                    NSUInteger n = r.length < 16 ? r.length : 16;
                    [s getCharacters:buf range:NSMakeRange(r.location, n)];
                    post(pid, 0, 0, buf, n);
                    j = r.location + r.length;
                }
                continue;
            }
            if (strncmp(tok, "sleep:", 6) == 0) {
                usleep((useconds_t)(atoi(tok + 6) * 1000));
                continue;
            }
            if (strncmp(tok, "raw16:", 6) == 0) {
                UniChar c = (UniChar)strtoul(tok + 6, NULL, 16);
                post(pid, 0, 0, &c, 1);
                continue;
            }
            CGEventFlags flags = 0;
            while (strlen(tok) > 2 && tok[1] == '-' && strchr("CMSs", tok[0])) {
                flags |= tok[0] == 'C'   ? kCGEventFlagMaskControl
                         : tok[0] == 'M' ? kCGEventFlagMaskAlternate
                         : tok[0] == 'S' ? kCGEventFlagMaskShift
                                         : kCGEventFlagMaskCommand;
                tok += 2;
            }
            const key *k = NULL;
            for (size_t j = 0; j < sizeof keys / sizeof keys[0]; j++) {
                if (strcmp(keys[j].name, tok) == 0) {
                    k = &keys[j];
                }
            }
            if (!k) {
                fprintf(stderr, "post_keys: unknown key %s\n", argv[i]);
                return 2;
            }
            post(pid, k->code, flags | (k->shift ? kCGEventFlagMaskShift : 0), NULL, 0);
        }
    }
    return 0;
}
