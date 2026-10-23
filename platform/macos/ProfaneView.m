#import "ProfaneView.h"

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "PFFont.h"
#import "PFMetalRenderer.h"
#import "PFShaper.h"

#include <math.h>

#include "pf_display.h"
#include "pf_layout.h"
#include "pf_window.h"
#include "pf_window_ffi.h"

/* Interim colors (modus-operandi / modus-vivendi) until theme design tokens land in M2. */
typedef struct PFPalette {
    uint32_t background, foreground;
} PFPalette;

static const PFPalette kLightPalette = {0xFFFFFFFF, 0x000000FF};
static const PFPalette kDarkPalette = {0x000000FF, 0xFFFFFFFF};

static const float kFontSize = 14.0f;
static const size_t kLayoutCacheLines = 4096;

/* A view backed by a CAMetalLayer that the render thread draws; AppKit never displays it. */
@interface PFMetalLayerView : NSView
@property (nonatomic) BOOL passesMouse;
- (instancetype)initWithFrame:(NSRect)frame device:(id<MTLDevice>)device opaque:(BOOL)opaque;
@end

@implementation PFMetalLayerView {
    id<MTLDevice> _device;
    BOOL _opaque;
}

- (instancetype)initWithFrame:(NSRect)frame device:(id<MTLDevice>)device opaque:(BOOL)opaque {
    if ((self = [super initWithFrame:frame])) {
        _device = device;
        _opaque = opaque;
        self.wantsLayer = YES; /* after _device: this calls -makeBackingLayer */
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawNever;
        self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    return self;
}

- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.presentsWithTransaction = YES; /* see -[PFMetalRenderer present:onLayer:index:] */
    layer.opaque = _opaque;
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    layer.colorspace = srgb;
    CGColorSpaceRelease(srgb);
    /* While a resize waits for the next frame, keep the old pixels pinned top-left rather
     * than stretched. */
    layer.contentsGravity = kCAGravityTopLeft;
    return layer;
}

- (BOOL)isOpaque {
    return _opaque;
}

- (NSView *)hitTest:(NSPoint)point {
    return self.passesMouse ? nil : [super hitTest:point];
}

@end

@implementation ProfaneView {
    PFMetalLayerView *_base;
    PFMetalLayerView *_overlay;
    PFMetalRenderer *_metal;
    pf_font_id _font;
    pf_layout_cache *_cache;
    pf_window *_window;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) {
        return nil;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
        return nil;
    }
    NSRect bounds = self.bounds;
    _base = [[PFMetalLayerView alloc] initWithFrame:bounds device:device opaque:YES];
    _nativeHost = [[NSView alloc] initWithFrame:bounds];
    _nativeHost.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    _overlay = [[PFMetalLayerView alloc] initWithFrame:bounds device:device opaque:NO];
    _overlay.passesMouse = YES;
    [self addSubview:_base];
    [self addSubview:_nativeHost];
    [self addSubview:_overlay];

    _metal = [[PFMetalRenderer alloc]
        initWithDevice:device
                layers:@[ (CAMetalLayer *)_base.layer, (CAMetalLayer *)_overlay.layer ]];
    if (!_metal) {
        return nil;
    }
    _font = pf_font_open("JetBrains Mono", kFontSize);
    _cache = pf_layout_cache_new(PFCoreTextShaper(), kLayoutCacheLines, 8);
    pf_window_style style = [self windowStyle];
    _window = pf_window_new(_cache, &style);
    _windowHandle = pf_win_register(_window);
    pf_win_set_selected(_windowHandle);
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_metal stop];
    pf_win_unregister(_windowHandle);
    pf_window_free(_window);
    pf_layout_cache_free(_cache);
}

- (pf_renderer *)renderer {
    return _metal.renderer;
}

- (NSUInteger)presentedFrames {
    return (NSUInteger)_metal.presentedFrames;
}

- (BOOL)isFlipped {
    return YES;
}

- (void)viewWillMoveToWindow:(NSWindow *)window {
    [super viewWillMoveToWindow:window];
    [NSNotificationCenter.defaultCenter removeObserver:self
                                                  name:NSWindowDidChangeOcclusionStateNotification
                                                object:nil];
    if (window) {
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(occlusionChanged:)
                                                   name:NSWindowDidChangeOcclusionStateNotification
                                                 object:window];
    }
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window) {
        [self updateScale];
        [_metal startWithView:self];
        [self rebuild];
    } else {
        [_metal stop];
    }
}

/* Frames presented before the window is on screen are dropped, and the render thread idles
 * once it has drawn, so redraw whenever the window becomes visible. */
- (void)occlusionChanged:(NSNotification *)note {
    (void)note;
    if (self.window.occlusionState & NSWindowOcclusionStateVisible) {
        [_metal redraw];
    }
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    [self updateScale];
    [self rebuild];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self rebuild];
}

- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    [self rebuild];
}

- (void)updateScale {
    CGFloat scale = self.window ? self.window.backingScaleFactor : 1.0;
    _base.layer.contentsScale = scale;
    _overlay.layer.contentsScale = scale;
}

- (pf_window_style)windowStyle {
    pf_font_metrics m = {0};
    pf_font_metrics_get(_font, &m);
    PFPalette palette = [self palette];
    /* Whole-point line boxes keep rows pixel-aligned at every scale. */
    return (pf_window_style){
        .font = _font,
        .ascent = roundf(m.ascent),
        .descent = m.descent,
        .line_height = ceilf(m.ascent + m.descent + m.leading),
        .cell_width = m.advance,
        .pad_left = 4,
        .pad_top = 2,
        .background = palette.background,
        .foreground = palette.foreground,
        .cursor = palette.foreground,
    };
}

- (PFPalette)palette {
    NSAppearanceName name = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua] ? kDarkPalette : kLightPalette;
}

static CGColorRef create_cgcolor(uint32_t c) {
    return CGColorCreateSRGB(((c >> 24) & 0xFF) / 255.0, ((c >> 16) & 0xFF) / 255.0,
                             ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0);
}

/* Style or geometry changed: update the window and the empty overlay, then redraw. */
- (void)rebuild {
    if (!self.window || !_metal) {
        return;
    }
    NSSize size = self.bounds.size;
    float scale = (float)self.window.backingScaleFactor;
    PFPalette palette = [self palette];
    CGColorRef background = create_cgcolor(palette.background);
    _base.layer.backgroundColor = background; /* shows under a resize until the next frame */
    CGColorRelease(background);

    pf_window_style style = [self windowStyle];
    pf_window_set_style(_window, &style);
    pf_window_set_size(_window, (float)size.width, (float)size.height, scale);
    [self redisplay];

    const pf_display *overlay =
        pf_display_finish(pf_display_new((float)size.width, (float)size.height, scale, 0));
    pf_renderer_submit(_metal.renderer, PF_LAYER_OVERLAY, overlay);
    pf_display_release(overlay);
}

- (void)redisplay {
    if (!self.window || !_metal) {
        return;
    }
    const pf_display *d = pf_window_redisplay(_window);
    if (d) {
        pf_renderer_submit(_metal.renderer, PF_LAYER_BASE, d);
        pf_display_release(d);
    }
}

- (BOOL)writeSnapshotToURL:(NSURL *)url {
    return [_metal writeSnapshotToURL:url];
}

@end
