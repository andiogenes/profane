#import "PFNativeViews.h"

@implementation PFNativeViewHost
- (BOOL)isFlipped {
    return YES;
}

/* Only the views placed here take events, not the empty host around them. */
- (NSView *)hitTest:(NSPoint)point {
    NSView *hit = [super hitTest:point];
    return hit == self ? nil : hit;
}
@end

/* A placeholder view: a tinted panel saying what it is. It takes no events, so keys and the
 * mouse stay with the editor. */
@interface PFStubView : NSView
@end

@implementation PFStubView
- (BOOL)isFlipped {
    return YES;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil;
}

- (void)drawRect:(NSRect)dirty {
    [[NSColor controlBackgroundColor] setFill];
    NSRectFill(self.bounds);
    [[NSColor separatorColor] setStroke];
    NSFrameRect(self.bounds);
    NSString *label = @"native view";
    NSDictionary *attrs = @{
        NSFontAttributeName : [NSFont systemFontOfSize:13],
        NSForegroundColorAttributeName : [NSColor secondaryLabelColor],
    };
    NSSize size = [label sizeWithAttributes:attrs];
    [label drawAtPoint:NSMakePoint((self.bounds.size.width - size.width) / 2,
                                   (self.bounds.size.height - size.height) / 2)
        withAttributes:attrs];
}
@end

@implementation PFNativeViews {
    NSView *_host;
    NSMutableDictionary<NSNumber *, NSView *> *_views;
    NSMutableDictionary<NSNumber *, NSNumber *> *_kinds;
    uint64_t _generation;
    BOOL _synced;
}

- (instancetype)initWithHost:(NSView *)host {
    if ((self = [super init])) {
        _host = host;
        _views = [NSMutableDictionary dictionary];
        _kinds = [NSMutableDictionary dictionary];
    }
    return self;
}

- (nullable NSView *)viewForWindowTag:(uint32_t)tag {
    return _views[@(tag)];
}

static NSView *make_view(uint32_t kind) {
    switch (kind) {
    case PF_NATIVE_KIND_STUB:
    default:
        return [[PFStubView alloc] initWithFrame:NSZeroRect];
    }
}

- (void)syncWithFrame:(pf_frame *)frame {
    uint64_t generation = pf_frame_native_generation(frame);
    if (_synced && generation == _generation) {
        return;
    }
    _synced = YES;
    _generation = generation;
    NSMutableSet<NSNumber *> *live = [NSMutableSet set];
    size_t n = pf_frame_native_count(frame);
    for (size_t i = 0; i < n; i++) {
        pf_native_placement p;
        if (pf_frame_native_get(frame, i, &p) != 0) {
            continue;
        }
        NSNumber *tag = @(p.tag);
        [live addObject:tag];
        NSView *view = _views[tag];
        if (view && _kinds[tag].unsignedIntValue != p.kind) {
            [view removeFromSuperview];
            view = nil;
        }
        if (!view) {
            view = make_view(p.kind);
            _views[tag] = view;
            _kinds[tag] = @(p.kind);
            [_host addSubview:view];
        }
        /* Whole points keep the view's edges on the pixel grid. */
        view.frame = NSMakeRect(roundf(p.x), roundf(p.y), roundf(p.w), roundf(p.h));
        view.hidden = !p.shown || p.w < 1 || p.h < 1;
    }
    for (NSNumber *tag in [_views allKeys]) {
        if (![live containsObject:tag]) {
            [_views[tag] removeFromSuperview];
            [_views removeObjectForKey:tag];
            [_kinds removeObjectForKey:tag];
        }
    }
}
@end
