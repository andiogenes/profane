#import "ProfaneView.h"

#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef struct PFColor {
    float r, g, b, a;
} PFColor;

typedef struct PFPalette {
    PFColor background;
    PFColor foreground;
} PFPalette;

/* Interim colors (modus-operandi / modus-vivendi) until theme design tokens land in M2. */
static const PFPalette kLightPalette = {{1.0f, 1.0f, 1.0f, 1.0f}, {0.0f, 0.0f, 0.0f, 1.0f}};
static const PFPalette kDarkPalette = {{0.0f, 0.0f, 0.0f, 1.0f}, {1.0f, 1.0f, 1.0f, 1.0f}};

static const CGFloat kFontSize = 14.0;

static CTFontRef create_code_font(CGFloat size) {
    CTFontRef font = CTFontCreateWithName(CFSTR("JetBrains Mono"), size, NULL);
    CFStringRef family = CTFontCopyFamilyName(font);
    BOOL found = family && CFStringCompare(family, CFSTR("JetBrains Mono"), 0) == kCFCompareEqualTo;
    if (family) {
        CFRelease(family);
    }
    if (found) {
        return font;
    }
    CFRelease(font);
    return CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, size, NULL);
}

@implementation ProfaneView {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _textPipeline;
    id<MTLTexture> _textTexture; /* coverage of `text` at _textScale, rebuilt lazily */
    CGFloat _textScale;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if (!(self = [super initWithFrame:frame])) {
        return nil;
    }
    _device = MTLCreateSystemDefaultDevice();
    if (!_device) {
        return nil;
    }
    _queue = [_device newCommandQueue];

    NSError *error = nil;
    id<MTLLibrary> library = [_device newDefaultLibrary];
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = [library newFunctionWithName:@"pf_text_vertex"];
    desc.fragmentFunction = [library newFunctionWithName:@"pf_text_fragment"];
    MTLRenderPipelineColorAttachmentDescriptor *color = desc.colorAttachments[0];
    color.pixelFormat = MTLPixelFormatBGRA8Unorm;
    color.blendingEnabled = YES;
    color.sourceRGBBlendFactor = MTLBlendFactorOne;
    color.sourceAlphaBlendFactor = MTLBlendFactorOne;
    color.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    color.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    _textPipeline = [_device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!_textPipeline) {
        NSLog(@"profane: text pipeline: %@", error);
        return nil;
    }

    _text = @"";
    /* Set after _device: turning on wantsLayer calls -makeBackingLayer. */
    self.wantsLayer = YES;
    self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;
    return self;
}

- (CALayer *)makeBackingLayer {
    CAMetalLayer *layer = [CAMetalLayer layer];
    layer.device = _device;
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    layer.framebufferOnly = YES;
    layer.opaque = YES;
    layer.presentsWithTransaction = YES; /* keeps frames in step with live resize */
    layer.needsDisplayOnBoundsChange = YES;
    return layer;
}

/* CAMetalLayer display goes through the layer delegate, not -updateLayer. */
- (void)displayLayer:(CALayer *)layer {
    (void)layer;
    [self render];
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    self.layer.contentsScale = self.window ? self.window.backingScaleFactor : 1.0;
    [self.layer setNeedsDisplay];
}

- (BOOL)isOpaque {
    return YES;
}

- (void)setText:(NSString *)text {
    _text = [text copy];
    _textTexture = nil;
    [self.layer setNeedsDisplay];
}

- (void)viewDidChangeBackingProperties {
    [super viewDidChangeBackingProperties];
    self.layer.contentsScale = self.window.backingScaleFactor;
    [self.layer setNeedsDisplay];
}

- (void)viewDidChangeEffectiveAppearance {
    [super viewDidChangeEffectiveAppearance];
    [self.layer setNeedsDisplay];
}

- (PFPalette)palette {
    NSAppearanceName name = [self.effectiveAppearance
        bestMatchFromAppearancesWithNames:@[ NSAppearanceNameAqua, NSAppearanceNameDarkAqua ]];
    return [name isEqualToString:NSAppearanceNameDarkAqua] ? kDarkPalette : kLightPalette;
}

- (nullable id<MTLTexture>)textTextureAtScale:(CGFloat)scale {
    if (_textTexture && _textScale == scale) {
        return _textTexture;
    }
    _textTexture = nil;
    _textScale = scale;
    if (_text.length == 0) {
        return nil;
    }

    CTFontRef font = create_code_font(kFontSize * scale);
    NSDictionary *attrs = @{
        (__bridge id)kCTFontAttributeName : (__bridge id)font,
        (__bridge id)kCTForegroundColorFromContextAttributeName : @YES,
    };
    NSAttributedString *string = [[NSAttributedString alloc] initWithString:_text attributes:attrs];
    CTLineRef line = CTLineCreateWithAttributedString((__bridge CFAttributedStringRef)string);
    CGFloat ascent = 0, descent = 0;
    double width = CTLineGetTypographicBounds(line, &ascent, &descent, NULL);
    size_t w = (size_t)ceil(width) + 2, h = (size_t)ceil(ascent + descent) + 2;

    /* Coverage only: the shader applies the color. Bitmap rows are stored top-down. */
    CGContextRef ctx = CGBitmapContextCreate(NULL, w, h, 8, 0, NULL, (CGBitmapInfo)kCGImageAlphaOnly);
    if (ctx) {
        CGContextSetTextPosition(ctx, 1, ceil(descent) + 1);
        CTLineDraw(line, ctx);
        MTLTextureDescriptor *desc =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                               width:w
                                                              height:h
                                                           mipmapped:NO];
        desc.usage = MTLTextureUsageShaderRead;
        desc.storageMode = MTLStorageModeShared;
        _textTexture = [_device newTextureWithDescriptor:desc];
        [_textTexture replaceRegion:MTLRegionMake2D(0, 0, w, h)
                        mipmapLevel:0
                          withBytes:CGBitmapContextGetData(ctx)
                        bytesPerRow:CGBitmapContextGetBytesPerRow(ctx)];
        CGContextRelease(ctx);
    }
    CFRelease(line);
    CFRelease(font);
    return _textTexture;
}

/* Encodes one frame of PX pixels into TARGET (a drawable or an offscreen snapshot texture). */
- (void)encodeFrameInto:(id<MTLTexture>)target
                   size:(CGSize)px
                  scale:(CGFloat)scale
               commands:(id<MTLCommandBuffer>)commands {
    PFPalette palette = [self palette];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor =
        MTLClearColorMake(palette.background.r, palette.background.g, palette.background.b, 1.0);

    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
    id<MTLTexture> text = [self textTextureAtScale:scale];
    if (text) {
        /* Centered, pixel-aligned; converted from top-down pixels to device coordinates. */
        double x0 = floor((px.width - (double)text.width) / 2);
        double y0 = floor((px.height - (double)text.height) / 2);
        float rect[4] = {
            (float)(x0 / px.width * 2 - 1),
            (float)(1 - y0 / px.height * 2),
            (float)((x0 + text.width) / px.width * 2 - 1),
            (float)(1 - (y0 + text.height) / px.height * 2),
        };
        [encoder setRenderPipelineState:_textPipeline];
        [encoder setVertexBytes:rect length:sizeof rect atIndex:0];
        [encoder setFragmentBytes:&palette.foreground length:sizeof palette.foreground atIndex:0];
        [encoder setFragmentTexture:text atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [encoder endEncoding];
}

- (CGSize)pixelSizeAtScale:(CGFloat)scale {
    return CGSizeMake(round(self.bounds.size.width * scale),
                      round(self.bounds.size.height * scale));
}

- (void)render {
    CAMetalLayer *layer = (CAMetalLayer *)self.layer;
    CGFloat scale = layer.contentsScale;
    CGSize px = [self pixelSizeAtScale:scale];
    if (px.width < 1 || px.height < 1) {
        return;
    }
    layer.drawableSize = px;
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) {
        return;
    }
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    [self encodeFrameInto:drawable.texture size:px scale:scale commands:commands];
    [commands commit];
    [commands waitUntilScheduled];
    [drawable present];
    _presentedFrames++;
}

- (BOOL)writeSnapshotToURL:(NSURL *)url {
    CGFloat scale = self.layer.contentsScale;
    CGSize px = [self pixelSizeAtScale:scale];
    if (px.width < 1 || px.height < 1) {
        return NO;
    }
    size_t w = (size_t)px.width, h = (size_t)px.height;
    MTLTextureDescriptor *desc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:w
                                                          height:h
                                                       mipmapped:NO];
    desc.usage = MTLTextureUsageRenderTarget;
    desc.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [_device newTextureWithDescriptor:desc];
    id<MTLCommandBuffer> commands = [_queue commandBuffer];
    [self encodeFrameInto:target size:px scale:scale commands:commands];
    [commands commit];
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
