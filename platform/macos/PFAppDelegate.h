#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface PFAppDelegate : NSObject <NSApplicationDelegate>

/* Headless runs Scheme and the socket REPL without a window or Dock icon (used by tests).
 * With a snapshot path, the first frame is written there as PNG and the app quits. */
- (instancetype)initWithHeadless:(BOOL)headless snapshotPath:(nullable NSString *)snapshotPath;
- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
