#import "PFAppDelegate.h"

#import "PFReplServer.h"
#import "PFScheme.h"
#import "ProfaneView.h"

#include "pf_repl.h"
#include "pf_scheme.h"

#include <stdlib.h>

@implementation PFAppDelegate {
    BOOL _headless;
    NSString *_snapshotPath;
    int _exitStatus;
    BOOL _schemeReady;
    NSWindow *_window;
    PFReplServer *_repl;
    ProfaneView *_view;
    CFRunLoopObserverRef _idleObserver;
}

- (instancetype)initWithHeadless:(BOOL)headless snapshotPath:(nullable NSString *)snapshotPath {
    if ((self = [super init])) {
        _headless = headless;
        _snapshotPath = [snapshotPath copy];
    }
    return self;
}

- (void)applicationWillFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSApp.activationPolicy =
        _headless ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular;
    if (!_headless) {
        NSApp.mainMenu = [self makeMainMenu];
    }
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    if (PFSchemeBoot() != 0) {
        NSLog(@"profane: failed to boot Chez Scheme");
        [NSApp terminate:nil];
        return;
    }
    _schemeReady = YES;
    [self installIdleObserver];
    [self startRepl];

    if (_headless) {
        return;
    }
    _window = [[NSWindow alloc]
        initWithContentRect:NSMakeRect(0, 0, 960, 640)
                  styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                            NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                    backing:NSBackingStoreBuffered
                      defer:NO];
    _window.title = @"profane";
    ProfaneView *view = [[ProfaneView alloc] initWithFrame:_window.contentLayoutRect];
    if (!view) {
        NSLog(@"profane: Metal is unavailable");
        [NSApp terminate:nil];
        return;
    }
    _window.contentView = view;
    _view = view;
    pf_scheme_call("pf-startup", NULL, 0, NULL); /* shows *scratch* in the selected window */
    [_window center];
    [_window makeKeyAndOrderFront:nil];
    [NSApp activate];

    if (_snapshotPath) {
        [self snapshotView:view attemptsLeft:100];
    }
}

/* Waits (up to ~5 s) for AppKit to present a frame on screen, so a view that never displays
 * fails instead of producing a correct-looking offscreen image. */
- (void)snapshotView:(ProfaneView *)view attemptsLeft:(int)attempts {
    if (view.presentedFrames == 0 && attempts > 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC),
                       dispatch_get_main_queue(), ^{
                           [self snapshotView:view attemptsLeft:attempts - 1];
                       });
        return;
    }
    if (view.presentedFrames == 0) {
        NSLog(@"profane: no frame was presented on screen");
        _exitStatus = 1;
    } else if (![view writeSnapshotToURL:[NSURL fileURLWithPath:_snapshotPath]]) {
        NSLog(@"profane: failed to write snapshot to %@", _snapshotPath);
        _exitStatus = 1;
    }
    [NSApp terminate:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    (void)sender;
    return !_headless;
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification;
    [_repl stop];
    _repl = nil;
    if (_idleObserver) {
        CFRunLoopObserverInvalidate(_idleObserver);
        CFRelease(_idleObserver);
        _idleObserver = NULL;
    }
    if (_schemeReady) {
        pf_scheme_deinit();
        _schemeReady = NO;
    }
    if (_exitStatus != 0) {
        exit(_exitStatus); /* -terminate: would exit 0 */
    }
}

/* Deferred GC and other idle work run just before the main run loop goes to sleep. */
- (void)installIdleObserver {
    _idleObserver = CFRunLoopObserverCreateWithHandler(
        kCFAllocatorDefault, kCFRunLoopBeforeWaiting, true, 0,
        ^(CFRunLoopObserverRef observer, CFRunLoopActivity activity) {
            (void)observer, (void)activity;
            pf_scheme_idle();
            [self->_view redisplay];
        });
    CFRunLoopAddObserver(CFRunLoopGetMain(), _idleObserver, kCFRunLoopCommonModes);
}

- (void)startRepl {
    char path[1024];
    if (pf_repl_socket_path(path, sizeof path) != 0) {
        NSLog(@"profane: REPL socket path too long; REPL disabled");
        return;
    }
    NSError *error = nil;
    _repl = [[PFReplServer alloc] initWithPath:@(path) error:&error];
    if (!_repl) {
        NSLog(@"profane: REPL disabled: %@", error.localizedDescription);
    }
}

- (NSMenu *)makeMainMenu {
    NSMenu *main = [NSMenu new];
    NSMenuItem *appItem = [main addItemWithTitle:@"" action:nil keyEquivalent:@""];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Hide profane" action:@selector(hide:) keyEquivalent:@"h"];
    [appMenu addItem:[NSMenuItem separatorItem]];
    [appMenu addItemWithTitle:@"Quit profane" action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = appMenu;
    return main;
}

@end
