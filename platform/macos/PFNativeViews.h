#import <AppKit/AppKit.h>

#include "pf_frame.h"

NS_ASSUME_NONNULL_BEGIN

/* Native-view window kinds (pf_frame_native_*): keeps one AppKit view per native window in a
 * host view, created by kind and placed on the window's body. The host is flipped, so frame
 * coordinates (top-left origin) apply directly. */

/* Kind numbers, as Scheme registers them (native-view-kinds in (profane window)). */
enum { PF_NATIVE_KIND_STUB = 1 };

@interface PFNativeViewHost : NSView
@end

@interface PFNativeViews : NSObject
- (instancetype)initWithHost:(NSView *)host;
/* Brings the views in line with F's native windows when anything about them changed. */
- (void)syncWithFrame:(pf_frame *)frame;
/* The view for window TAG, if any (tests, and web/PDF setup later). */
- (nullable NSView *)viewForWindowTag:(uint32_t)tag;
@end

NS_ASSUME_NONNULL_END
