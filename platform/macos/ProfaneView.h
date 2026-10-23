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

/* The view's text window, as a pf_handle for Scheme; registered as the selected window. */
@property (nonatomic, readonly) uint32_t windowHandle;
/* The renderer for this view's layers. */
@property (nonatomic, readonly) pf_renderer *renderer;
/* Subviews placed here sit between the base and overlay layers. */
@property (nonatomic, readonly) NSView *nativeHost;
/* Frames presented on screen so far; lets tests tell "drawn" from "never displayed". */
@property (nonatomic, readonly) NSUInteger presentedFrames;

/* Renders the window again if its buffer, point, size or style changed. Called after input
 * and from the idle observer (so edits from the REPL show up too). */
- (void)redisplay;

/* -initWithFrame: returns nil when no Metal device is available. */
- (nullable instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/* Renders the newest frame of all layers offscreen and writes it as PNG. Needs no
 * screen-recording permission; the seam for Metal golden-image tests. */
- (BOOL)writeSnapshotToURL:(NSURL *)url;

@end

/* Foreign entries for Scheme: the main view's input latency (pf_renderer_latency) as text, and
 * a reset. The report is truncated to CAP bytes; returns its full length. */
size_t pf_app_latency_report(char *out, size_t cap);
void pf_app_latency_reset(void);

NS_ASSUME_NONNULL_END
