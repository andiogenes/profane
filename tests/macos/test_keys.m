/* Key descriptions from synthetic events: independent of the user's active layout. */

#import <AppKit/AppKit.h>

#import "PFKeys.h"

#include "pf_test.h"

static NSString *describe(unsigned short code, NSString *chars, NSString *ignoring,
                          NSEventModifierFlags flags, BOOL *direct) {
    NSEvent *e = [NSEvent keyEventWithType:NSEventTypeKeyDown
                                  location:NSZeroPoint
                             modifierFlags:flags
                                 timestamp:0
                              windowNumber:0
                                   context:nil
                                characters:chars
               charactersIgnoringModifiers:ignoring
                                 isARepeat:NO
                                   keyCode:code];
    return PFKeyDescription(e, direct);
}

#define CHECK_KEY(code, chars, ignoring, flags, expected, expect_direct)                           \
    do {                                                                                           \
        BOOL d_ = NO;                                                                              \
        NSString *k_ = describe(code, chars, ignoring, flags, &d_);                                \
        PF_CHECK_EQ_STR(k_.UTF8String, expected);                                                  \
        PF_CHECK(d_ == (expect_direct));                                                           \
    } while (0)

int main(void) {
    @autoreleasepool {
        NSEventModifierFlags C = NSEventModifierFlagControl, M = NSEventModifierFlagOption;
        NSEventModifierFlags S = NSEventModifierFlagShift, s = NSEventModifierFlagCommand;

        /* Plain keys go through the input method, chords and named keys do not. */
        CHECK_KEY(0, @"a", @"a", 0, "a", NO);
        CHECK_KEY(49, @" ", @" ", 0, "SPC", NO);
        CHECK_KEY(36, @"\r", @"\r", 0, "RET", YES);
        CHECK_KEY(51, @"\x7f", @"\x7f", 0, "DEL", YES);
        CHECK_KEY(123, @"", @"", 0, "<left>", YES);
        CHECK_KEY(123, @"", @"", S, "S-<left>", YES);
        CHECK_KEY(3, @"\x06", @"f", C, "C-f", YES);
        CHECK_KEY(43, @"≤", @"<", M | S, "M-<", YES); /* not M-S-<: Shift is in the "<" */
        CHECK_KEY(44, @"\x1f", @"/", C, "C-/", YES);
        CHECK_KEY(27, @"\x1f", @"_", C | M | S, "C-M-_", YES);
        CHECK_KEY(12, @"q", @"q", s, "s-q", YES);

        /* (Assumes a QWERTY-family ASCII-capable layout, as on the dev machines.)
         * Regression: with a Russian layout active the event says "ф" for the A key, which made
         * every chord unbound ("C-ф"). Chords use the ASCII-capable layout's character. */
        CHECK_KEY(0, @"\x01", @"ф", C, "C-a", YES);
        CHECK_KEY(14, @"\x05", @"у", C, "C-e", YES);
        CHECK_KEY(3, @"а", @"а", M, "M-f", YES);
        /* ...while plain typing keeps the active layout's character. */
        CHECK_KEY(0, @"ф", @"ф", 0, "ф", NO);
    }
    return PF_TEST_RESULT();
}
