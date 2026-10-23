#import <AppKit/AppKit.h>

#include "pf_renderer.h"

NS_ASSUME_NONNULL_BEGIN

/* The editor surface: three stacked layers, bottom to top —
 *   base Metal layer      text windows, mode lines, fringes   (PF_LAYER_BASE)
 *   native view host      WKWebView / AppKit views (M11)
 *   overlay Metal layer   pop-ups, completion, jump labels   (PF_LAYER_OVERLAY)
 * Both Metal layers are drawn by the pf_renderer render thread from submitted display lists;
 * the overlay is transparent and never takes mouse events. */
@interface ProfaneView : NSView

@property (nonatomic, copy) NSString *text;
/* The renderer for this view's layers. */
@property (nonatomic, readonly) pf_renderer *renderer;
/* Subviews placed here sit between the base and overlay layers. */
@property (nonatomic, readonly) NSView *nativeHost;
/* Frames presented on screen so far; lets tests tell "drawn" from "never displayed". */
@property (nonatomic, readonly) NSUInteger presentedFrames;

/* -initWithFrame: returns nil when no Metal device is available. */
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/* Renders the newest frame of all layers offscreen and writes it as PNG. Needs no
 * screen-recording permission; the seam for Metal golden-image tests. */
- (BOOL)writeSnapshotToURL:(NSURL *)url;

@end

NS_ASSUME_NONNULL_END
