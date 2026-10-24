#import "PFMacOS.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Security/Security.h>

static NSData *stash;

static int64_t keep(NSString *s) {
    stash = [s dataUsingEncoding:NSUTF8StringEncoding];
    if (!stash) {
        stash = [NSData data];
    }
    return (int64_t)stash.length;
}

int64_t pf_app_stash_length(void) {
    return stash ? (int64_t)stash.length : 0;
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

static int64_t PFKeychainFail(OSStatus status) {
    if (status == errSecItemNotFound) {
        return -1;
    }
    CFStringRef message = SecCopyErrorMessageString(status, NULL);
    NSString *text = message ? CFBridgingRelease(message) : nil;
    if (!text) {
        text = [NSString stringWithFormat:@"Keychain error %d", (int)status];
    }
    keep(text);
    return -2;
}

static NSMutableDictionary *PFKeychainQuery(const void *service, size_t slen, const void *account,
                                            size_t alen) {
    NSString *svc = PFString(service, slen);
    NSString *acct = PFString(account, alen);
    if (!svc || !acct) {
        return nil;
    }
    return [@{
        (id)kSecClass : (id)kSecClassGenericPassword,
        (id)kSecAttrService : svc,
        (id)kSecAttrAccount : acct,
    } mutableCopy];
}

int64_t pf_app_secret_get(const void *service, size_t slen, const void *account, size_t alen) {
    NSMutableDictionary *query = PFKeychainQuery(service, slen, account, alen);
    if (!query) {
        keep(@"service and account must be UTF-8");
        return -2;
    }
    query[(id)kSecReturnData] = @YES;
    query[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status != errSecSuccess) {
        return PFKeychainFail(status);
    }
    NSData *data = CFBridgingRelease(result);
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!text) {
        keep(@"the stored secret is not UTF-8 text");
        return -2;
    }
    return keep(text);
}

int64_t pf_app_secret_set(const void *service, size_t slen, const void *account, size_t alen,
                          const void *value, size_t vlen) {
    NSMutableDictionary *query = PFKeychainQuery(service, slen, account, alen);
    if (!query) {
        keep(@"service and account must be UTF-8");
        return -2;
    }
    NSData *data = [NSData dataWithBytes:value length:vlen];
    NSMutableDictionary *add = [query mutableCopy];
    add[(id)kSecValueData] = data;
    OSStatus status = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
    if (status == errSecDuplicateItem) {
        status = SecItemUpdate((__bridge CFDictionaryRef)query,
                               (__bridge CFDictionaryRef) @{(id)kSecValueData : data});
    }
    return status == errSecSuccess ? 0 : PFKeychainFail(status);
}

int64_t pf_app_secret_delete(const void *service, size_t slen, const void *account, size_t alen) {
    NSMutableDictionary *query = PFKeychainQuery(service, slen, account, alen);
    if (!query) {
        keep(@"service and account must be UTF-8");
        return -2;
    }
    OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
    return status == errSecSuccess ? 0 : PFKeychainFail(status);
}
