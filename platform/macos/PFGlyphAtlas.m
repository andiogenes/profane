#import "PFGlyphAtlas.h"

#import <CoreText/CoreText.h>

#import "PFFont.h"

#include <math.h>
#include <stdlib.h>
#include <string.h>

enum { GRAY_SIZE = 2048, COLOR_SIZE = 1024, PAD = 1 };

/* Shelf packing: glyphs fill rows left to right; a row is as tall as its tallest glyph. */
typedef struct shelf_packer {
    int size, x, y, row_h;
} shelf_packer;

static BOOL shelf_place(shelf_packer *p, int w, int h, int *ox, int *oy) {
    if (w > p->size || h > p->size) {
        return NO;
    }
    if (p->x + w > p->size) {
        p->x = 0;
        p->y += p->row_h;
        p->row_h = 0;
    }
    if (p->y + h > p->size) {
        return NO;
    }
    *ox = p->x;
    *oy = p->y;
    p->x += w;
    if (h > p->row_h) {
        p->row_h = h;
    }
    return YES;
}

/* Open-addressing map from (font, glyph, bin) to entry. Key 0 marks an empty slot. */
typedef struct slot {
    uint64_t key;
    PFGlyphEntry entry;
} slot;

static uint64_t make_key(pf_font_id font, uint32_t glyph, int bin) {
    return ((uint64_t)font << 34 | (uint64_t)(glyph & 0xFFFFFFFF) << 2 | (uint64_t)bin) + 1;
}

static uint64_t mix(uint64_t k) {
    k ^= k >> 33;
    k *= 0xff51afd7ed558ccdull;
    k ^= k >> 33;
    return k;
}

@implementation PFGlyphAtlas {
    shelf_packer _gray, _color;
    slot *_slots;
    size_t _cap, _used;
    CGFloat _scale;
    /* Fonts at pixel size, indexed by font id; rebuilt when the scale changes. */
    CTFontRef *_scaled;
    size_t _scaledCap;
}

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device {
    if (!(self = [super init])) {
        return nil;
    }
    MTLTextureDescriptor *gray =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                           width:GRAY_SIZE
                                                          height:GRAY_SIZE
                                                       mipmapped:NO];
    gray.storageMode = MTLStorageModeShared;
    MTLTextureDescriptor *color =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:COLOR_SIZE
                                                          height:COLOR_SIZE
                                                       mipmapped:NO];
    color.storageMode = MTLStorageModeShared;
    _grayTexture = [device newTextureWithDescriptor:gray];
    _colorTexture = [device newTextureWithDescriptor:color];
    if (!_grayTexture || !_colorTexture) {
        return nil;
    }
    _scale = 1;
    [self reset];
    return self;
}

- (void)dealloc {
    free(_slots);
    [self dropScaledFonts];
    free(_scaled);
}

- (void)dropScaledFonts {
    for (size_t i = 0; i < _scaledCap; i++) {
        if (_scaled[i]) {
            CFRelease(_scaled[i]);
            _scaled[i] = NULL;
        }
    }
}

- (void)reset {
    _gray = (shelf_packer){GRAY_SIZE, 0, 0, 0};
    _color = (shelf_packer){COLOR_SIZE, 0, 0, 0};
    free(_slots);
    _cap = 4096;
    _used = 0;
    _slots = calloc(_cap, sizeof *_slots);
}

- (void)setScale:(CGFloat)scale {
    if (scale != _scale) {
        _scale = scale;
        [self dropScaledFonts];
        [self reset];
    }
}

- (nullable CTFontRef)scaledFont:(pf_font_id)font {
    if (font >= _scaledCap) {
        size_t cap = font + 16;
        CTFontRef *grown = realloc(_scaled, cap * sizeof *grown);
        if (!grown) {
            return NULL;
        }
        memset(grown + _scaledCap, 0, (cap - _scaledCap) * sizeof *grown);
        _scaled = grown;
        _scaledCap = cap;
    }
    if (!_scaled[font]) {
        CTFontRef base = PFFontGet(font);
        if (!base) {
            return NULL;
        }
        _scaled[font] = CTFontCreateCopyWithAttributes(base, CTFontGetSize(base) * _scale, NULL, NULL);
    }
    return _scaled[font];
}

- (slot *)findSlot:(uint64_t)key {
    size_t mask = _cap - 1;
    for (size_t i = mix(key) & mask;; i = (i + 1) & mask) {
        if (_slots[i].key == key || _slots[i].key == 0) {
            return &_slots[i];
        }
    }
}

- (void)grow {
    slot *old = _slots;
    size_t oldCap = _cap;
    _cap *= 2;
    _slots = calloc(_cap, sizeof *_slots);
    for (size_t i = 0; i < oldCap; i++) {
        if (old[i].key) {
            *[self findSlot:old[i].key] = old[i];
        }
    }
    free(old);
}

- (BOOL)entryForFont:(pf_font_id)font glyph:(uint32_t)glyph bin:(int)bin entry:(PFGlyphEntry *)out {
    uint64_t key = make_key(font, glyph, bin);
    slot *s = [self findSlot:key];
    if (s->key == key) {
        *out = s->entry;
        return YES;
    }
    PFGlyphEntry entry;
    if (![self rasterizeFont:font glyph:(CGGlyph)glyph bin:bin entry:&entry]) {
        return NO;
    }
    if ((_used + 1) * 10 > _cap * 7) {
        [self grow];
        s = [self findSlot:key];
    }
    s->key = key;
    s->entry = entry;
    _used++;
    *out = entry;
    return YES;
}

- (BOOL)rasterizeFont:(pf_font_id)font glyph:(CGGlyph)glyph bin:(int)bin entry:(PFGlyphEntry *)out {
    memset(out, 0, sizeof *out);
    CTFontRef f = [self scaledFont:font];
    if (!f) {
        return YES; /* unknown font: draw nothing */
    }
    CGRect bounds;
    CTFontGetBoundingRectsForGlyphs(f, kCTFontOrientationHorizontal, &glyph, &bounds, 1);
    if (CGRectIsEmpty(bounds)) {
        return YES; /* space and friends */
    }
    double dx = (double)bin / PF_ATLAS_SUBPIXEL_BINS;
    int x0 = (int)floor(CGRectGetMinX(bounds) + dx) - PAD;
    int x1 = (int)ceil(CGRectGetMaxX(bounds) + dx) + PAD;
    int y0 = (int)floor(CGRectGetMinY(bounds)) - PAD;
    int y1 = (int)ceil(CGRectGetMaxY(bounds)) + PAD;
    int w = x1 - x0, h = y1 - y0;

    BOOL color = (CTFontGetSymbolicTraits(f) & kCTFontTraitColorGlyphs) != 0;
    int ax, ay;
    if (!shelf_place(color ? &_color : &_gray, w, h, &ax, &ay)) {
        return NO;
    }

    CGColorSpaceRef space = color ? CGColorSpaceCreateWithName(kCGColorSpaceSRGB) : NULL;
    CGContextRef ctx = CGBitmapContextCreate(
        NULL, (size_t)w, (size_t)h, 8, 0, space,
        color ? (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little
              : (CGBitmapInfo)kCGImageAlphaOnly);
    if (space) {
        CGColorSpaceRelease(space);
    }
    if (!ctx) {
        return YES;
    }
    CGContextSetShouldAntialias(ctx, true);
    CGContextSetShouldSubpixelPositionFonts(ctx, true);
    CGContextSetShouldSubpixelQuantizeFonts(ctx, false);
    CGPoint pos = CGPointMake(dx - x0, -y0);
    CTFontDrawGlyphs(f, &glyph, &pos, 1, ctx);

    id<MTLTexture> tex = color ? _colorTexture : _grayTexture;
    [tex replaceRegion:MTLRegionMake2D((NSUInteger)ax, (NSUInteger)ay, (NSUInteger)w, (NSUInteger)h)
           mipmapLevel:0
             withBytes:CGBitmapContextGetData(ctx)
           bytesPerRow:CGBitmapContextGetBytesPerRow(ctx)];
    CGContextRelease(ctx);

    *out = (PFGlyphEntry){(uint16_t)ax, (uint16_t)ay, (uint16_t)w, (uint16_t)h,
                          (int16_t)x0, (int16_t)y1, color ? PFAtlasPageColor : PFAtlasPageGray};
    return YES;
}

@end
