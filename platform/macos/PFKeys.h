#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/* Emacs-style description of a key event: modifiers C- M- S- s- (Option is Meta; S- only for
 * named keys such as "<left>", as Shift is already in the character) plus a key name or
 * character. Sets *DIRECT when the event must bypass the input method (modifier chords and
 * named keys).
 *
 * Chords are named after the key in the current ASCII-capable layout, so C-f is the F key
 * even while typing with a Russian (or any non-Latin) layout; plain typing keeps the active
 * layout and input method. */
NSString *PFKeyDescription(NSEvent *event, BOOL *direct);

NS_ASSUME_NONNULL_END
