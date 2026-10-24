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

#include "pf_anim.h"
#include "pf_display.h"
#include "pf_display_ffi.h"
#include "pf_face.h"
#include "pf_frame.h"
#import "PFNativeViews.h"
#include "pf_input.h"
#include "pf_layout.h"
#include "pf_scheme.h"
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

static int font_metrics(void *ctx, uint32_t font, pf_font_metrics *out) {
    (void)ctx;
    return pf_font_metrics_get(font, out);
}

static uint32_t font_scaled(void *ctx, uint32_t font, float factor) {
    (void)ctx;
    return pf_font_scaled(font, factor);
}

static const pf_font_source font_source = {NULL, font_metrics, font_scaled};

@implementation ProfaneView {
    double _inputTime; /* timestamp of the event being handled, 0 if none */
    BOOL _animScheduled; /* a redisplay for the animations in flight is queued */
    NSString *_marked; /* input-method composition, nil when none */
    NSRange _markedSelection;
    NSEvent *_interpreting; /* the key event inside -interpretKeyEvents: */
    PFMetalLayerView *_base;
    PFMetalLayerView *_overlay;
    PFMetalRenderer *_metal;
    pf_font_id _font;
    pf_layout_cache *_cache;
    pf_frame *_frame;
    PFNativeViews *_nativeViews;
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
    _nativeHost = [[PFNativeViewHost alloc] initWithFrame:bounds];
    _nativeViews = [[PFNativeViews alloc] initWithHost:_nativeHost];
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
    _frame = pf_frame_new(_cache, &font_source, _font);
    _frameHandle = pf_frm_register(_frame);
    pf_frm_set_selected(_frameHandle);
    [NSNotificationCenter.defaultCenter addObserver:self
                                           selector:@selector(systemColorsChanged:)
                                               name:NSSystemColorsDidChangeNotification
                                             object:nil];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [_metal stop];
    pf_frm_unregister(_frameHandle);
    pf_frame_free(_frame);
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
        [self reportAccent];
        [self reportAppearance];
        [self reportReduceMotion];
        [[NSWorkspace.sharedWorkspace notificationCenter]
            addObserver:self
               selector:@selector(reportReduceMotion)
                   name:NSWorkspaceAccessibilityDisplayOptionsDidChangeNotification
                 object:nil];
        [self rebuild];
    } else {
        [[NSWorkspace.sharedWorkspace notificationCenter] removeObserver:self];
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

/* The macOS accent color, for themes that use system-accent. */
- (void)reportAccent {
    NSColor *c = [NSColor.controlAccentColor colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    char hex[8];
    snprintf(hex, sizeof hex, "#%02x%02x%02x", (int)lround(c.redComponent * 255),
             (int)lround(c.greenComponent * 255), (int)lround(c.blueComponent * 255));
    pf_scheme_arg arg = PF_SCHEME_STRING(hex, strlen(hex));
    pf_scheme_call("pf-accent-changed", &arg, 1, NULL);
}

- (void)systemColorsChanged:(NSNotification *)note {
    (void)note;
    [self reportAccent];
    [self redisplay];
}

/* Trackpad pinch scales text (profane display: text scale). */
- (void)magnifyWithEvent:(NSEvent *)event {
    char amount[32];
    snprintf(amount, sizeof amount, "%.4f", event.magnification);
    pf_scheme_arg arg = PF_SCHEME_STRING(amount, strlen(amount));
    pf_scheme_call("pf-pinch", &arg, 1, NULL);
    [self redisplay];
}

/* macOS "Reduce Motion" switches every animation off (pf_anim.h). */
- (void)reportReduceMotion {
    pf_motion_set_reduced(NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion);
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

/* Geometry changed: resize the frame, then redraw. */
- (void)rebuild {
    if (!self.window || !_metal) {
        return;
    }
    NSSize size = self.bounds.size;
    float scale = (float)self.window.backingScaleFactor;
    CGColorRef background = create_cgcolor(pf_face_default_background());
    _base.layer.backgroundColor = background; /* shows under a resize until the next frame */
    CGColorRelease(background);

    pf_frame_set_size(_frame, (float)size.width, (float)size.height, scale);
    [self redisplay]; /* the resize also redraws the overlay (pop-ups) */
}

- (void)redisplay {
    if (!self.window || !_metal) {
        return;
    }
    pf_scheme_call("pf-redisplay", NULL, 0, NULL);
    pf_frame_tick(_frame, CACurrentMediaTime());
    [_nativeViews syncWithFrame:_frame]; /* windows of native kinds: views over their bodies */
    const pf_display *d = pf_frame_redisplay(_frame);
    if (d) { /* shows under a resize until the next frame */
        CGColorRef background = create_cgcolor(pf_display_clear(d));
        _base.layer.backgroundColor = background;
        CGColorRelease(background);
    }
    if (d && _inputTime > 0) {
        pf_renderer_mark_input(_metal.renderer, _inputTime);
    }
    _inputTime = 0;
    if (d) {
        pf_renderer_submit(_metal.renderer, PF_LAYER_BASE, d);
        pf_display_release(d);
    }
    /* Pop-up surfaces: Scheme's canvases, redrawn by pf-redisplay above. */
    const pf_display *overlay = pf_frame_redisplay_overlay(_frame);
    if (overlay) {
        pf_renderer_submit(_metal.renderer, PF_LAYER_OVERLAY, overlay);
        pf_display_release(overlay);
    }
    [self scheduleAnimationFrame];
}

/* While something animates, redisplay again about one refresh later. It is a plain main-queue
 * block, so keys and the REPL are handled between frames, and a frame that comes late makes the
 * animation arrive at once (pf_window_tick) instead of slowing input down. */
- (void)scheduleAnimationFrame {
    if (_animScheduled || !pf_frame_animating(_frame)) {
        return;
    }
    _animScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 120)),
                   dispatch_get_main_queue(), ^{
                       self->_animScheduled = NO;
                       [self redisplay];
                   });
}

/* ---- input ---- */

- (BOOL)acceptsFirstResponder {
    return YES;
}

/* ---- mouse ----
 * Events go to Scheme (profane mouse) as strings in frame coordinates (points, top-left origin;
 * the view is flipped). The shell only asks C for the cursor shape. */

- (BOOL)acceptsFirstMouse:(NSEvent *)event {
    return YES; /* the click that focuses the window also acts, as in Emacs */
}

- (NSPoint)framePoint:(NSEvent *)event {
    return [self convertPoint:event.locationInWindow fromView:nil];
}

- (void)sendMouse:(const char *)kind event:(NSEvent *)event {
    NSPoint p = [self framePoint:event];
    char text[96];
    snprintf(text, sizeof text, "%s %.2f %.2f %ld", kind, p.x, p.y, (long)event.clickCount);
    _inputTime = event.timestamp;
    send_string("pf-mouse", [NSString stringWithUTF8String:text]);
    [self redisplay];
}

- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    [self sendMouse:"down" event:event];
}

- (void)mouseDragged:(NSEvent *)event {
    [self sendMouse:"drag" event:event];
}

- (void)mouseUp:(NSEvent *)event {
    [self sendMouse:"up" event:event];
}

- (void)scrollWheel:(NSEvent *)event {
    NSPoint p = [self framePoint:event];
    BOOL precise = event.hasPreciseScrollingDeltas;
    /* Points for a trackpad; lines for a wheel (Scheme scales them). Momentum is delivered as
     * more events, so there is nothing to do for it. */
    double dx = precise ? event.scrollingDeltaX : event.deltaX;
    double dy = precise ? event.scrollingDeltaY : event.deltaY;
    char text[128];
    snprintf(text, sizeof text, "scroll %.2f %.2f %.2f %.2f %d", p.x, p.y, dx, dy, precise ? 1 : 0);
    send_string("pf-mouse", [NSString stringWithUTF8String:text]);
    [self redisplay];
}

- (void)updateCursorFor:(NSEvent *)event {
    NSPoint p = [self framePoint:event];
    switch (pf_frame_cursor_at(_frame, (float)p.x, (float)p.y)) {
    case 1:
        [[NSCursor pointingHandCursor] set];
        break;
    case 2:
        [[NSCursor IBeamCursor] set];
        break;
    default:
        [[NSCursor arrowCursor] set];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    [self updateCursorFor:event];
}

- (void)cursorUpdate:(NSEvent *)event {
    [self updateCursorFor:event];
}

- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    for (NSTrackingArea *area in self.trackingAreas) {
        [self removeTrackingArea:area];
    }
    [self addTrackingArea:[[NSTrackingArea alloc]
                              initWithRect:NSZeroRect
                                   options:NSTrackingMouseMoved | NSTrackingCursorUpdate |
                                           NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
                                     owner:self
                                  userInfo:nil]];
}

- (void)keyDown:(NSEvent *)event {
    _inputTime = event.timestamp;
    BOOL direct = NO;
    NSString *key = PFKeyDescription(event, pf_input_prefix_pending() && !_marked, &direct);
    if (direct && !_marked) {
        send_string("pf-key", key);
        [self redisplay];
        return;
    }
    /* Plain keys go through the input method: it may insert text, compose, or ask for a
     * command (-doCommandBySelector:). macOS reads the press-and-hold default as the key goes
     * down, so it is set for this key: off (the key repeats) unless Scheme listed it. */
    [self setPressAndHold:pf_input_press_and_hold(key.UTF8String) != 0];
    _interpreting = event;
    [self interpretKeyEvents:@[ event ]];
    _interpreting = nil;
    [self redisplay];
}

- (void)setPressAndHold:(BOOL)on {
    static BOOL current = NO;
    if (on != current) {
        current = on;
        [[NSUserDefaults standardUserDefaults] setBool:on forKey:@"ApplePressAndHoldEnabled"];
    }
}

- (void)doCommandBySelector:(SEL)selector {
    (void)selector;
    if (_interpreting) {
        BOOL direct;
        send_string("pf-key", PFKeyDescription(_interpreting, NO, &direct));
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
    pf_window *w = pf_frame_selected(_frame);
    if (w) {
        pf_window_set_preedit(w, cps, n, caret);
    }
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
    NSRect rect = pf_frame_cursor_rect(_frame, r) == 0 ? NSMakeRect(r[0], r[1], r[2], r[3])
                                                         : NSMakeRect(0, 0, 0, 0);
    return [self.window convertRectToScreen:[self convertRect:rect toView:nil]];
}

- (BOOL)writeSnapshotToURL:(NSURL *)url {
    return [_metal writeSnapshotToURL:url];
}

@end
