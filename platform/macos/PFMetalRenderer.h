#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>

#include "pf_renderer.h"

NS_ASSUME_NONNULL_BEGIN

/* Metal implementation of pf_renderer. A dedicated render thread, woken by the view's display
 * link, encodes the newest display list of each changed layer and presents it. It is the only
 * thread that touches the layers' drawables (and their drawableSize). It pauses the display
 * link when idle and resumes on submit. */
@interface PFMetalRenderer : NSObject

@property (nonatomic, readonly) pf_renderer *renderer;
/* Frames actually presented on screen (counted by presented handlers). */
@property (nonatomic, readonly) uint64_t presentedFrames;

/* LAYERS are indexed by pf_layer. */
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                 layers:(NSArray<CAMetalLayer *> *)layers;
- (instancetype)init NS_UNAVAILABLE;

/* Starts the render thread with a display link from VIEW (main thread). */
- (void)startWithView:(NSView *)view;
- (void)stop;

/* Presents every layer's newest list again, e.g. when the window becomes visible: frames
 * presented while it was not on screen are dropped silently. Any thread. */
- (void)redraw;

/* Draws the newest display lists, composited bottom to top, offscreen and writes a PNG.
 * Synchronous; any thread. */
- (BOOL)writeSnapshotToURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
