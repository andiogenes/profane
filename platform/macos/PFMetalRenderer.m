#import "PFMetalRenderer.h"

#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#import "PFGlyphAtlas.h"
#import "PFShaderTypes.h"

#include <math.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <stdlib.h>

/* Ticks with nothing to draw before the display link is paused. A committed frame counts as
 * shown only once its presented handler fires: frames presented while the window is not yet
 * on screen are dropped without notice. An unconfirmed frame is presented again every
 * CONFIRM_TICKS, at most MAX_REPRESENTS times, before giving up until the next submit. */
enum { IDLE_TICKS_BEFORE_PAUSE = 30, CONFIRM_TICKS = 15, MAX_REPRESENTS = 10 };

struct pf_renderer {
    void *owner; /* PFMetalRenderer, unretained: it owns this struct */
};

@interface PFMetalRenderer ()
- (void)submit:(const pf_display *)display layer:(pf_layer)layer;
- (void)tick;
@end

void pf_renderer_submit(pf_renderer *r, pf_layer layer, const pf_display *display) {
    [(__bridge PFMetalRenderer *)r->owner submit:display layer:layer];
}

uint64_t pf_renderer_presented_frames(const pf_renderer *r) {
    return ((__bridge PFMetalRenderer *)r->owner).presentedFrames;
}

/* Display link target; keeps the link from retaining the renderer. */
@interface PFRenderTick : NSObject
@property (nonatomic, weak) PFMetalRenderer *renderer;
@end

@implementation PFMetalRenderer {
    pf_renderer _c;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _pipeline;
    PFGlyphAtlas *_atlas;
    NSArray<CAMetalLayer *> *_layers;

    os_unfair_lock _pendingLock; /* guards _pending */
    const pf_display *_pending[PF_LAYER_COUNT];
    const pf_display *_shown[PF_LAYER_COUNT]; /* render thread: newest taken per layer */
    BOOL _retry[PF_LAYER_COUNT];               /* render thread: present _shown next tick */
    uint64_t _committed[PF_LAYER_COUNT];       /* render thread: generation last committed */
    atomic_uint_fast64_t _confirmed[PF_LAYER_COUNT]; /* generation last actually presented */
    uint64_t _committedAt[PF_LAYER_COUNT];     /* tick of that commit */
    int _represents[PF_LAYER_COUNT];
    uint64_t _ticks;
    int _dropDrawables;                        /* test hook, see -initWithDevice:layers: */

    NSLock *_encodeLock; /* atlas + encoding: render thread vs snapshots */
    id<MTLCommandBuffer> _lastCommands;
    atomic_uint_fast64_t _presented;

    NSThread *_thread;
    CFRunLoopRef _runLoop;
    CADisplayLink *_link;
    PFRenderTick *_tick;
    int _idleTicks;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device
                                 layers:(NSArray<CAMetalLayer *> *)layers {
    if (!(self = [super init])) {
        return nil;
    }
    _c.owner = (__bridge void *)self;
    _device = device;
    _queue = [device newCommandQueue];
    _layers = [layers copy];
    _atlas = [[PFGlyphAtlas alloc] initWithDevice:device];
    _pendingLock = OS_UNFAIR_LOCK_INIT;
    _encodeLock = [NSLock new];
    atomic_init(&_presented, 0);
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        atomic_init(&_confirmed[i], 0);
    }
    /* Test hook: discard the first N drawables, as if the layer could not provide them (e.g.
     * the window is not on screen yet), to exercise the retry path deterministically. */
    const char *drop = getenv("PROFANE_TEST_DROP_DRAWABLES");
    _dropDrawables = drop ? atoi(drop) : 0;

    id<MTLLibrary> library = [device newDefaultLibrary];
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"pf_quad_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"pf_quad_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatBGRA8Unorm;
    color.blendingEnabled = YES; /* premultiplied over */
    color.sourceRGBBlendFactor = MTLBlendFactorOne;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    NSError *error = nil;
    _pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_queue || !_atlas || !_pipeline) {
        NSLog(@"profane: renderer setup failed: %@", error);
        return nil;
    }
    return self;
}

- (void)dealloc {
    [self stop];
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        pf_display_release(_pending[i]);
        pf_display_release(_shown[i]);
    }
}

- (pf_renderer *)renderer {
    return &_c;
}

- (uint64_t)presentedFrames {
    return atomic_load(&_presented);
}

/* ---- submission (any thread) ---- */

- (void)submit:(const pf_display *)display layer:(pf_layer)layer {
    pf_display_retain(display);
    os_unfair_lock_lock(&_pendingLock);
    const pf_display *old = _pending[layer];
    _pending[layer] = display;
    os_unfair_lock_unlock(&_pendingLock);
    pf_display_release(old);
    [self wake];
}

- (void)redraw {
    CFRunLoopRef rl = _runLoop;
    if (!rl) {
        return;
    }
    CFRunLoopPerformBlock(rl, kCFRunLoopDefaultMode, ^{
        for (int i = 0; i < PF_LAYER_COUNT; i++) {
            if (self->_shown[i]) {
                self->_retry[i] = YES;
                self->_represents[i] = 0;
            }
        }
    });
    [self wake];
}

- (void)wake {
    CFRunLoopRef rl = _runLoop;
    if (!rl) {
        return;
    }
    CFRunLoopPerformBlock(rl, kCFRunLoopDefaultMode, ^{
        self->_idleTicks = 0;
        self->_link.paused = NO;
    });
    CFRunLoopWakeUp(rl);
}

/* ---- render thread ---- */

- (void)startWithView:(NSView *)view {
    if (_thread) {
        return;
    }
    _tick = [PFRenderTick new];
    _tick.renderer = self;
    _link = [view displayLinkWithTarget:_tick selector:@selector(tick:)];
    CADisplayLink *link = _link;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __weak PFMetalRenderer *weakSelf = self;
    _thread = [[NSThread alloc] initWithBlock:^{
        PFMetalRenderer *strong = weakSelf;
        if (!strong) {
            dispatch_semaphore_signal(ready);
            return;
        }
        strong->_runLoop = CFRunLoopGetCurrent();
        [link addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
        strong = nil;
        dispatch_semaphore_signal(ready);
        CFRunLoopRun();
    }];
    _thread.name = @"profane.render";
    _thread.qualityOfService = NSQualityOfServiceUserInteractive;
    [_thread start];
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
}

- (void)stop {
    CFRunLoopRef rl = _runLoop;
    if (!rl) {
        return;
    }
    CADisplayLink *link = _link;
    CFRunLoopPerformBlock(rl, kCFRunLoopDefaultMode, ^{
        [link invalidate];
        CFRunLoopStop(CFRunLoopGetCurrent());
    });
    CFRunLoopWakeUp(rl);
    _runLoop = NULL;
    _link = nil;
    _thread = nil;
}

- (void)tick {
    _ticks++;
    BOOL waiting = NO;
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        if (_committed[i] == atomic_load(&_confirmed[i]) || _represents[i] >= MAX_REPRESENTS) {
            continue; /* shown, or given up */
        }
        waiting = YES;
        if (_ticks - _committedAt[i] >= CONFIRM_TICKS) {
            _retry[i] = YES;
            _represents[i]++;
        }
    }
    BOOL changed[PF_LAYER_COUNT] = {NO};
    BOOL any = NO;
    os_unfair_lock_lock(&_pendingLock);
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        if (_pending[i]) {
            pf_display_release(_shown[i]);
            _shown[i] = _pending[i];
            _pending[i] = NULL;
            _retry[i] = YES;
            _represents[i] = 0;
        }
        changed[i] = _retry[i];
        any = any || changed[i];
    }
    os_unfair_lock_unlock(&_pendingLock);

    if (!any) {
        if (!waiting && ++_idleTicks >= IDLE_TICKS_BEFORE_PAUSE) {
            _link.paused = YES;
        }
        return;
    }
    _idleTicks = 0;
    /* A layer whose present failed stays dirty and is retried next tick; dropping it would
     * leave the window blank until the next change (the link pauses when idle). */
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        if (changed[i]) {
            _retry[i] = ![self present:_shown[i] onLayer:_layers[i] index:i];
        }
    }
}

/* Returns NO if no frame could be encoded (no drawable yet); YES once it is committed, or if
 * there is nothing to draw (zero size). */
- (BOOL)present:(const pf_display *)display onLayer:(CAMetalLayer *)layer index:(int)index {
    CGSize px = CGSizeMake(round(pf_display_width(display) * pf_display_scale(display)),
                           round(pf_display_height(display) * pf_display_scale(display)));
    if (px.width < 1 || px.height < 1) {
        return YES;
    }
    if (!CGSizeEqualToSize(layer.drawableSize, px)) {
        /* Layer changes on a background thread open an implicit transaction that nothing
         * commits (only the main run loop does), leaving the layer stale until some unrelated
         * main-thread transaction flushes it. Commit explicitly. */
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        layer.drawableSize = px;
        [CATransaction commit];
    }
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (drawable && _dropDrawables > 0) {
        _dropDrawables--;
        drawable = nil;
    }
    if (!drawable) {
        return NO;
    }
    [_encodeLock lock];
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    [self encode:display into:drawable.texture clear:YES commands:commands];
    /* Count every presented handler: presentedTime reads 0 even for frames visibly shown in a
     * window (it is only meaningful for direct-to-display presentation), so it can't filter. */
    uint64_t generation = ++_committed[index];
    _committedAt[index] = _ticks;
    [drawable addPresentedHandler:^(id<MTLDrawable> d) {
        (void)d;
        atomic_store(&self->_confirmed[index], generation);
        atomic_fetch_add(&self->_presented, 1);
    }];
    /* Present straight from the command buffer: lowest latency. (Presenting inside an explicit
     * CA transaction with presentsWithTransaction was tried and reverted: the "lost frames" it
     * seemed to fix were a measurement artifact — macOS does not refresh a fully covered
     * window, and captures of it are stale — while it blocked this thread on
     * waitUntilScheduled. Uncovered windows show current content either way.) */
    [commands presentDrawable:drawable];
    [commands commit];
    _lastCommands = commands;
    [_encodeLock unlock];
    return YES;
}

/* ---- encoding (under _encodeLock) ---- */

static MTLClearColor premultiplied(uint32_t c) {
    double a = (c & 0xFF) / 255.0;
    return MTLClearColorMake(((c >> 24) & 0xFF) / 255.0 * a, ((c >> 16) & 0xFF) / 255.0 * a,
                             ((c >> 8) & 0xFF) / 255.0 * a, a);
}

/* Converts DISPLAY into quad instances. Returns NO if the atlas filled up midway. */
- (BOOL)buildQuads:(const pf_display *)display into:(NSMutableData *)out {
    float s = pf_display_scale(display);
    const pf_display_item *items = pf_display_items(display);
    size_t n = pf_display_count(display);
    out.length = 0;
    float gw = (float)_atlas.grayTexture.width, gh = (float)_atlas.grayTexture.height;
    float cw = (float)_atlas.colorTexture.width, ch = (float)_atlas.colorTexture.height;
    for (size_t i = 0; i < n; i++) {
        const pf_display_item *it = &items[i];
        PFQuadInstance q = {0};
        q.color = it->color;
        if (it->kind == PF_DISPLAY_RECT) {
            q.rect = simd_make_float4(it->x * s, it->y * s, it->u.rect.w * s, it->u.rect.h * s);
            q.mode = PF_QUAD_RECT;
        } else {
            float pen = it->x * s;
            float base = floorf(pen);
            int bin = (int)((pen - base) * PF_ATLAS_SUBPIXEL_BINS) % PF_ATLAS_SUBPIXEL_BINS;
            PFGlyphEntry e;
            if (![_atlas entryForFont:it->u.glyph.font glyph:it->u.glyph.glyph bin:bin entry:&e]) {
                return NO;
            }
            if (e.w == 0) {
                continue;
            }
            float baseline = roundf(it->y * s);
            q.rect = simd_make_float4(base + e.ox, baseline - e.oy, e.w, e.h);
            float pw = e.page == PFAtlasPageColor ? cw : gw, ph = e.page == PFAtlasPageColor ? ch : gh;
            q.uv = simd_make_float4(e.x / pw, e.y / ph, (e.x + e.w) / pw, (e.y + e.h) / ph);
            q.mode = e.page == PFAtlasPageColor ? PF_QUAD_GLYPH_COLOR : PF_QUAD_GLYPH_GRAY;
        }
        [out appendBytes:&q length:sizeof q];
    }
    return YES;
}

- (void)encode:(const pf_display *)display
          into:(id<MTLTexture>)target
         clear:(BOOL)clear
      commands:(id<MTLCommandBuffer>)commands {
    [_atlas setScale:pf_display_scale(display)];
    NSMutableData *quads = [NSMutableData data];
    if (![self buildQuads:display into:quads]) {
        /* Atlas full: let the GPU finish reading it, start over, and rebuild this frame. */
        [_lastCommands waitUntilCompleted];
        [_atlas reset];
        if (![self buildQuads:display into:quads]) {
            NSLog(@"profane: one frame needs more glyphs than the atlas holds");
        }
    }

    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = clear ? MTLLoadActionClear : MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = premultiplied(pf_display_clear(display));
    id<MTLRenderCommandEncoder> enc = [commands renderCommandEncoderWithDescriptor:pass];
    NSUInteger count = quads.length / sizeof(PFQuadInstance);
    if (count > 0) {
        simd_float2 viewport = simd_make_float2((float)target.width, (float)target.height);
        id<MTLBuffer> buffer = [_device newBufferWithBytes:quads.bytes
                                                    length:quads.length
                                                   options:MTLResourceStorageModeShared];
        [enc setRenderPipelineState:_pipeline];
        [enc setVertexBuffer:buffer offset:0 atIndex:0];
        [enc setVertexBytes:&viewport length:sizeof viewport atIndex:1];
        [enc setFragmentTexture:_atlas.grayTexture atIndex:0];
        [enc setFragmentTexture:_atlas.colorTexture atIndex:1];
        [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip
                vertexStart:0
                vertexCount:4
              instanceCount:count];
    }
    [enc endEncoding];
}

/* ---- snapshots ---- */

- (BOOL)writeSnapshotToURL:(NSURL *)url {
    const pf_display *lists[PF_LAYER_COUNT] = {NULL};
    os_unfair_lock_lock(&_pendingLock);
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        const pf_display *d = _pending[i] ? _pending[i] : _shown[i];
        lists[i] = d ? pf_display_retain(d) : NULL;
    }
    os_unfair_lock_unlock(&_pendingLock);
    const pf_display *base = lists[PF_LAYER_BASE];
    BOOL ok = NO;
    if (base) {
        size_t w = (size_t)round(pf_display_width(base) * pf_display_scale(base));
        size_t h = (size_t)round(pf_display_height(base) * pf_display_scale(base));
        ok = w > 0 && h > 0 && [self writeLists:lists width:w height:h toURL:url];
    }
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        pf_display_release(lists[i]);
    }
    return ok;
}

- (BOOL)writeLists:(const pf_display *const *)lists
             width:(size_t)w
            height:(size_t)h
             toURL:(NSURL *)url {
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:desc];
    [_encodeLock lock];
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    for (int i = 0; i < PF_LAYER_COUNT; i++) {
        if (lists[i]) {
            [self encode:lists[i] into:target clear:i == PF_LAYER_BASE commands:commands];
        }
    }
    [commands commit];
    _lastCommands = commands;
    [_encodeLock unlock];
    [commands waitUntilCompleted];

    NSMutableData *pixels = [NSMutableData dataWithLength:w * h * 4];
    [target getBytes:pixels.mutableBytes
         bytesPerRow:w * 4
          fromRegion:MTLRegionMake2D(0, 0, w, h)
         mipmapLevel:0];
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)pixels);
    CGImageRef image =
        CGImageCreate(w, h, 8, 32, w * 4, srgb,
                      kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaPremultipliedFirst,
                      provider, NULL, false, kCGRenderingIntentDefault);
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)UTTypePNG.identifier, 1, NULL);
    BOOL ok = NO;
    if (image && dest) {
        CGImageDestinationAddImage(dest, image, NULL);
        ok = CGImageDestinationFinalize(dest);
    }
    if (dest) {
        CFRelease(dest);
    }
    CGImageRelease(image);
    CGDataProviderRelease(provider);
    CGColorSpaceRelease(srgb);
    return ok;
}

@end

@implementation PFRenderTick

- (void)tick:(CADisplayLink *)link {
    (void)link;
    [self.renderer tick];
}

@end
