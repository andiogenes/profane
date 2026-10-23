#import "PFKeys.h"

#import <Carbon/Carbon.h>

/* The character KEYCODE types in the current ASCII-capable layout (Shift applied), or nil. */
static NSString *_Nullable ascii_layout_char(unsigned short keycode, BOOL shift) {
    TISInputSourceRef source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
    if (!source) {
        return nil;
    }
    NSString *result = nil;
    CFDataRef data = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData);
    if (data) {
        const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        UInt32 dead = 0;
        UniChar buf[4];
        UniCharCount len = 0;
        UInt32 mods = shift ? (shiftKey >> 8) & 0xFF : 0;
        OSStatus status = UCKeyTranslate(layout, keycode, kUCKeyActionDown, mods, LMGetKbdType(),
                                         kUCKeyTranslateNoDeadKeysBit, &dead, 4, &len, buf);
        if (status == noErr && len > 0) {
            result = [NSString stringWithCharacters:buf length:len];
        }
    }
    CFRelease(source);
    return result;
}

NSString *PFKeyDescription(NSEvent *event, BOOL *direct) {
    NSEventModifierFlags flags = event.modifierFlags;
    NSString *chars = event.charactersIgnoringModifiers;
    unichar c = chars.length ? [chars characterAtIndex:0] : 0;
    NSString *name = nil;
    switch (c) {
    case NSUpArrowFunctionKey: name = @"<up>"; break;
    case NSDownArrowFunctionKey: name = @"<down>"; break;
    case NSLeftArrowFunctionKey: name = @"<left>"; break;
    case NSRightArrowFunctionKey: name = @"<right>"; break;
    case NSHomeFunctionKey: name = @"<home>"; break;
    case NSEndFunctionKey: name = @"<end>"; break;
    case NSPageUpFunctionKey: name = @"<prior>"; break;
    case NSPageDownFunctionKey: name = @"<next>"; break;
    case NSDeleteFunctionKey: name = @"<deletechar>"; break;
    case 0x7F: name = @"DEL"; break;
    case '\r': case 0x03: name = @"RET"; break;
    case '\t': name = @"TAB"; break;
    case 0x19: name = @"<backtab>"; break;
    case 0x1B: name = @"ESC"; break;
    default:
        if (c >= NSF1FunctionKey && c <= NSF35FunctionKey) {
            name = [NSString stringWithFormat:@"<f%d>", c - NSF1FunctionKey + 1];
        }
    }
    BOOL chord = (flags & (NSEventModifierFlagControl | NSEventModifierFlagOption |
                           NSEventModifierFlagCommand)) != 0;
    *direct = chord || name != nil;
    if (!name && chord) {
        name = ascii_layout_char(event.keyCode, (flags & NSEventModifierFlagShift) != 0);
    }
    if (!name) {
        name = chars;
    }
    if ([name isEqualToString:@" "]) {
        name = @"SPC";
    }
    NSMutableString *key = [NSMutableString string];
    if (flags & NSEventModifierFlagControl) {
        [key appendString:@"C-"];
    }
    if (flags & NSEventModifierFlagOption) {
        [key appendString:@"M-"];
    }
    if ((flags & NSEventModifierFlagShift) && name.length > 1 && [name hasPrefix:@"<"]) {
        [key appendString:@"S-"];
    }
    if (flags & NSEventModifierFlagCommand) {
        [key appendString:@"s-"];
    }
    [key appendString:name ? name : @""];
    return key;
}
