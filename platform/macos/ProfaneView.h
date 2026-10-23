#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/* The editor surface. M0: a CAMetalLayer that is cleared and shows one Core Text line, drawn
 * on the main thread on demand. M1 replaces this with the pf_renderer interface, the
 * display-link render thread and the three-layer stack (base Metal, native views, overlay). */
@interface ProfaneView : NSView

@property (nonatomic, copy) NSString *text;
/* Frames presented to the on-screen layer; lets tests tell "drawn" from "never displayed". */
@property (nonatomic, readonly) NSUInteger presentedFrames;

/* -initWithFrame: returns nil when no Metal device is available. */
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/* Renders the current frame offscreen at the backing scale and writes it as PNG. Needs no
 * screen-recording permission; the seam for Metal golden-image tests. */
- (BOOL)writeSnapshotToURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
