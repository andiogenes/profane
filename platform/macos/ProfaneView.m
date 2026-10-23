#import "ProfaneView.h"

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "PFFont.h"
#import "PFKeys.h"
#import "PFMetalRenderer.h"
#import "PFShaper.h"

#include <math.h>

#include <string.h>

#include "pf_display.h"
#include "pf_display_ffi.h"
#include "pf_scheme.h"
#include "pf_layout.h"
#include "pf_window.h"
#include "pf_window_ffi.h"

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

/* Sends S to Scheme as UTF-8. Text from events can contain unpaired surrogates, for which
 * -UTF8String returns NULL (that crashed the app); they become U+FFFD instead. */
static void send_string(const char *proc, NSString *s) {
    NSMutableString *clean = [NSMutableString stringWithCapacity:s.length];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        BOOL high = c >= 0xD800 && c <= 0xDBFF, low = c >= 0xDC00 && c <= 0xDFFF;
        if (high && i + 1 < s.length) {
            unichar next = [s characterAtIndex:i + 1];
            if (next >= 0xDC00 && next <= 0xDFFF) {
                [clean appendFormat:@"%C%C", c, next];
                i++;
                continue;
            }
        }
        [clean appendFormat:@"%C", (unichar)(high || low ? 0xFFFD : c)];
    }
    const char *utf8 = clean.UTF8String;
    if (!utf8) {
        return;
    }
    pf_scheme_arg arg = PF_SCHEME_STRING(utf8, strlen(utf8));
    pf_scheme_call(proc, &arg, 1, NULL);
}

@interface ProfaneView () <NSTextInputClient>
@end

static pf_renderer *main_renderer; /* the latest view's renderer, for the latency report */

size_t pf_app_latency_report(char *out, size_t cap) {
    if (!main_renderer) {
        return (size_t)snprintf(out, cap, "no renderer");
    }
    pf_latency_stats s = pf_renderer_latency(main_renderer);
    int n = snprintf(out, cap,
                     "samples %zu (ms from key event; p50 / p95 / max)\n"
                     "  submit   %6.2f %6.2f %6.2f   input, command, redisplay\n"
                     "  commit   %6.2f %6.2f %6.2f   frame encoded and committed\n"
                     "  present  %6.2f %6.2f %6.2f   presented handler (refresh, compositing)",
                     s.samples, s.submit[0], s.submit[1], s.submit[2], s.commit[0], s.commit[1],
                     s.commit[2], s.present[0], s.present[1], s.present[2]);
    return n > 0 ? (size_t)n : 0;
}

void pf_app_latency_reset(void) {
    if (main_renderer) {
        pf_renderer_latency_reset(main_renderer);
    }
}

@implementation ProfaneView {
    double _inputTime; /* timestamp of the event being handled, 0 if none */
    NSString *_marked; /* input-method composition, nil when none */
    NSRange _markedSelection;
    NSEvent *_interpreting; /* the key event inside -interpretKeyEvents: */
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
    main_renderer = _metal.renderer;
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
        [self reportAppearance];
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
    [self reportAppearance];
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

/* Geometry and the default font; colors come from Scheme's faces (profane display). */
- (pf_window_style)windowStyle {
    pf_font_metrics m = {0};
    pf_font_metrics_get(_font, &m);
    /* Whole-point line boxes keep rows pixel-aligned at every scale. */
    return (pf_window_style){
        .font = _font,
        .ascent = roundf(m.ascent),
        .descent = m.descent,
        .line_height = ceilf(m.ascent + m.descent + m.leading),
        .cell_width = m.advance,
        .pad_left = 4,
        .pad_top = 2,
    };
}

/* Tells Scheme whether macOS is in light or dark mode; it restyles the faces. */
- (void)reportAppearance {
    NSAppearanceName name = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    const char *which = [name isEqualToString:NSAppearanceNameDarkAqua] ? "dark" : "light";
    pf_scheme_arg arg = PF_SCHEME_STRING(which, strlen(which));
    pf_scheme_call("pf-appearance-changed", &arg, 1, NULL);
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
    CGColorRef background = create_cgcolor(pf_face_default_background());
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
    if (d && _inputTime > 0) {
        pf_renderer_mark_input(_metal.renderer, _inputTime);
    }
    _inputTime = 0;
    if (d) {
        pf_renderer_submit(_metal.renderer, PF_LAYER_BASE, d);
        pf_display_release(d);
    }
}

/* ---- input ---- */

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (void)keyDown:(NSEvent *)event {
    _inputTime = event.timestamp;
    BOOL direct = NO;
    NSString *key = PFKeyDescription(event, &direct);
    if (direct && !_marked) {
        send_string("pf-key", key);
        [self redisplay];
        return;
    }
    /* Plain keys go through the input method: it may insert text, compose, or ask for a
     * command (-doCommandBySelector:). */
    _interpreting = event;
    [self interpretKeyEvents:@[ event ]];
    _interpreting = nil;
    [self redisplay];
}

- (void)doCommandBySelector:(SEL)selector {
    (void)selector;
    if (_interpreting) {
        BOOL direct;
        send_string("pf-key", PFKeyDescription(_interpreting, &direct));
    }
}

- (void)insertText:(id)string replacementRange:(NSRange)range {
    (void)range;
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    [self clearMarked];
    if (text.length) {
        send_string("pf-insert-text", text);
    }
    [self redisplay];
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selected replacementRange:(NSRange)range {
    (void)range;
    NSString *text = [string isKindOfClass:NSAttributedString.class] ? [string string] : string;
    _marked = text.length ? [text copy] : nil;
    _markedSelection = selected;
    [self updatePreedit];
    [self redisplay];
}

- (void)unmarkText {
    NSString *text = _marked;
    [self clearMarked];
    if (text.length) {
        send_string("pf-insert-text", text);
    }
    [self redisplay];
}

- (void)clearMarked {
    _marked = nil;
    [self updatePreedit];
}

/* Hands the composition to the window as code points; the caret (a UTF-16 offset from the
 * input method) becomes a character index. */
- (void)updatePreedit {
    NSString *m = _marked ? _marked : @"";
    NSUInteger len = m.length;
    uint32_t *cps = malloc((len ? len : 1) * sizeof *cps);
    size_t n = 0, caret = 0;
    for (NSUInteger i = 0; i < len; i++) {
        if (i == _markedSelection.location) {
            caret = n;
        }
        uint32_t c = [m characterAtIndex:i];
        if (c >= 0xD800 && c <= 0xDBFF && i + 1 < len) {
            uint32_t lo = [m characterAtIndex:i + 1];
            if (lo >= 0xDC00 && lo <= 0xDFFF) {
                c = 0x10000 + ((c - 0xD800) << 10) + (lo - 0xDC00);
                i++;
            }
        }
        cps[n++] = c;
    }
    if (_markedSelection.location >= len) {
        caret = n;
    }
    pf_window_set_preedit(_window, cps, n, caret);
    free(cps);
}

- (BOOL)hasMarkedText {
    return _marked != nil;
}

- (NSRange)markedRange {
    return _marked ? NSMakeRange(0, _marked.length) : NSMakeRange(NSNotFound, 0);
}

- (NSRange)selectedRange {
    return _marked ? _markedSelection : NSMakeRange(0, 0);
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (nullable NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range
                                                         actualRange:(nullable NSRangePointer)actual {
    (void)range, (void)actual;
    return nil; /* no reconversion of buffer text yet */
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    (void)point;
    return NSNotFound;
}

/* Where the input method puts its candidate window: under the cursor. */
- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(nullable NSRangePointer)actual {
    (void)range;
    if (actual) {
        *actual = range;
    }
    float r[4];
    NSRect rect = pf_window_cursor_rect(_window, r) == 0 ? NSMakeRect(r[0], r[1], r[2], r[3])
                                                         : NSMakeRect(0, 0, 0, 0);
    return [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
}

- (BOOL)writeSnapshotToURL:(NSURL *)url {
    return [_metal writeSnapshotToURL:url];
}

@end
