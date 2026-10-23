#import <AppKit/AppKit.h>

#import "PFAppDelegate.h"
#import "PFScheme.h"

#include <stdio.h>
#include <string.h>

#include "pf_scheme.h"

static int run_self_test(void) {
    if (PFSchemeBoot() != 0) {
        return 2;
    }
    pf_scheme_result result;
    int status = pf_scheme_call("pf-self-test", NULL, 0, &result);
    if (status == 0) {
        printf("%s\n", result.text ? result.text : "ok");
        pf_scheme_result_free(&result);
    }
    pf_scheme_deinit();
    return status == 0 ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    BOOL headless = NO;
    NSString *snapshotPath = nil;
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--self-test") == 0) {
            return run_self_test();
        }
        if (strcmp(argv[i], "--headless") == 0) {
            headless = YES;
        } else if (strcmp(argv[i], "--snapshot") == 0 && i + 1 < argc) {
            snapshotPath = @(argv[++i]);
        }
    }
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        PFAppDelegate *delegate = [[PFAppDelegate alloc] initWithHeadless:headless snapshotPath:snapshotPath];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
