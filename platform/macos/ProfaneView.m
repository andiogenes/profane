#import "ProfaneView.h"

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "PFFont.h"
#import "PFMetalRenderer.h"

#include "pf_display.h"

/* Interim colors (modus-operandi / modus-vivendi) until theme design tokens land in M2. */
typedef struct PFPalette {
    uint32_t background, foreground;
} PFPalette;

static const PFPalette kLightPalette = {0xFFFFFFFF, 0x000000FF};
static const PFPalette kDarkPalette = {0x000000FF, 0xFFFFFFFF};

static const float kFontSize = 14.0f;

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
    _text = @"";
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_metal stop];
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

- (void)setText:(NSString *)text {
    _text = [text copy];
    [self rebuild];
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

- (PFPalette)palette {
    NSAppearanceName name = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua] ? kDarkPalette : kLightPalette;
}

static CGColorRef create_cgcolor(uint32_t c) {
    return CGColorCreateSRGB(((c >> 24) & 0xFF) / 255.0, ((c >> 16) & 0xFF) / 255.0,
                             ((c >> 8) & 0xFF) / 255.0, (c & 0xFF) / 255.0);
}

/* Rebuilds and submits both layers' display lists. Interim content until the display engine
 * (layout cache, windows) lands: one centered line of text. */
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

    pf_display *base =
        pf_display_new((float)size.width, (float)size.height, scale, palette.background);
    [self addLine:_text toDisplay:base size:size color:palette.foreground];
    const pf_display *frozen = pf_display_finish(base);
    pf_renderer_submit(_metal.renderer, PF_LAYER_BASE, frozen);
    pf_display_release(frozen);

    const pf_display *overlay =
        pf_display_finish(pf_display_new((float)size.width, (float)size.height, scale, 0));
    pf_renderer_submit(_metal.renderer, PF_LAYER_OVERLAY, overlay);
    pf_display_release(overlay);
}

- (void)addLine:(NSString *)text
      toDisplay:(pf_display *)display
           size:(NSSize)size
          color:(uint32_t)color {
    CTFontRef font = PFFontGet(_font);
    if (!font || text.length == 0) {
        return;
    }
    NSDictionary *attrs = @{(__bridge id)kCTFontAttributeName : (__bridge id)font};
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat ascent = 0, descent = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    float x0 = (float)floor((size.width - width) / 2);
    float baseline = (float)floor((size.height - (ascent + descent)) / 2 + ascent);

    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        /* Core Text may substitute a fallback font for some characters (emoji, CJK). */
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        pf_font_id fid = runFont ? PFFontIdForCTFont(runFont) : _font;
        CFIndex n = CTRunGetGlyphCount(run);
        if (n <= 0) {
            continue;
        }
        CGGlyph *glyphs = malloc((size_t)n * sizeof *glyphs);
        CGPoint *positions = malloc((size_t)n * sizeof *positions);
        CTRunGetGlyphs(run, CFRangeMake(0, n), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, n), positions);
        for (CFIndex i = 0; i < n; i++) {
            pf_display_glyph(display, fid, glyphs[i], x0 + (float)positions[i].x, baseline, color);
        }
        free(glyphs);
        free(positions);
    }
    CFRelease(line);
}

- (BOOL)writeSnapshotToURL:(NSURL *)url {
    return [_metal writeSnapshotToURL:url];
}

@end
