#import "PFMacOS.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

static NSData *stash;

static int64_t keep(NSString *s) {
    stash = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!stash) {
        stash = [NSData data];
    }
    return (int64_t)stash.length;
}

void pf_app_stash_copy(void *buf, size_t cap) {
    if (stash) {
        memcpy(buf, stash.bytes, MIN(cap, stash.length));
    }
}

static NSString *PFString(const void *bytes, size_t len) {
    return [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding];
}

static NSPasteboard *PFPasteboard(void) {
    const char *name = getenv("PROFANE_PASTEBOARD");
    return name && *name ? [NSPasteboard pasteboardWithName:@(name)] : NSPasteboard.generalPasteboard;
}

int64_t pf_app_pasteboard_string(void) {
    NSString *s = [PFPasteboard() stringForType:NSPasteboardTypeString];
    return s ? keep(s) : -1;
}

int64_t pf_app_pasteboard_set(const void *bytes, size_t len) {
    NSString *s = PFString(bytes, len);
    NSPasteboard *pb = PFPasteboard();
    [pb clearContents];
    if (s) {
        [pb setString:s forType:NSPasteboardTypeString];
    }
    return pb.changeCount;
}

int64_t pf_app_pasteboard_count(void) {
    return PFPasteboard().changeCount;
}

int pf_app_open_url(const void *url, size_t len, int activate) {
    NSString *s = PFString(url, len);
    NSURL *u = s.length ? [NSURL URLWithString:s] : nil;
    if (!u || !u.scheme) {
        return 0;
    }
    NSWorkspaceOpenConfiguration *config = [NSWorkspaceOpenConfiguration configuration];
    config.activates = activate != 0;
    [NSWorkspace.sharedWorkspace openURL:u configuration:config completionHandler:nil];
    return 1;
}

int64_t pf_app_applescript(const void *source, size_t len) {
    NSString *src = PFString(source, len);
    if (!src) {
        return -keep(@"source is not valid UTF-8");
    }
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:src];
    NSDictionary *error = nil;
    NSAppleEventDescriptor *result = [script executeAndReturnError:&error];
    if (!result) {
        NSString *message = error[NSAppleScriptErrorMessage];
        if (!message) {
            message = @"AppleScript failed";
        }
        return -keep(message);
    }
    NSString *text = result.stringValue;
    return keep(text ? text : @"");
}

int64_t pf_app_window_bounds(const void *query, size_t len) {
    NSString *q = PFString(query, len);
    int pid = q.intValue;
    BOOL byPid = pid > 0 && [@(pid).stringValue isEqualToString:q];
    NSArray *windows = CFBridgingRelease(CGWindowListCopyWindowInfo(
        kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    NSMutableString *out = [NSMutableString string];
    for (NSDictionary *w in windows) {
        if ([w[(id)kCGWindowLayer] intValue] != 0) {
            continue;
        }
        BOOL match = byPid ? [w[(id)kCGWindowOwnerPID] intValue] == pid
                           : [w[(id)kCGWindowOwnerName] isEqualToString:q];
        CGRect r;
        if (match && CGRectMakeWithDictionaryRepresentation(
                         (__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) {
            [out appendFormat:@"%.0f %.0f %.0f %.0f\n", r.origin.x, r.origin.y, r.size.width,
                              r.size.height];
        }
    }
    return keep(out);
}
