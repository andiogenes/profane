#import <Metal/Metal.h>

#include "pf_font.h"

NS_ASSUME_NONNULL_BEGIN

enum { PF_ATLAS_SUBPIXEL_BINS = 4 };

typedef NS_ENUM(uint8_t, PFAtlasPage) {
    PFAtlasPageGray = 0,  /* R8 coverage, tinted by the item color */
    PFAtlasPageColor = 1, /* BGRA premultiplied (emoji) */
};

/* Where a rasterized glyph lives: a W x H pixel box in PAGE at (X, Y). OX/OY place the box's
 * top-left relative to the pen at the baseline (OY up). W == 0 for glyphs with no ink. */
typedef struct PFGlyphEntry {
    uint16_t x, y, w, h;
    int16_t ox, oy;
    PFAtlasPage page;
} PFGlyphEntry;

/* Glyph cache in two GPU textures, filled on demand by rasterizing with Core Text. Render
 * thread only (the renderer serializes access). */
@interface PFGlyphAtlas : NSObject

@property (nonatomic, readonly) id<MTLTexture> grayTexture;
@property (nonatomic, readonly) id<MTLTexture> colorTexture;

- (nullable instancetype)initWithDevice:(id<MTLDevice>)device;
- (instancetype)init NS_UNAVAILABLE;

/* Pixels per point the glyphs are rasterized for; changing it empties the atlas. */
- (void)setScale:(CGFloat)scale;

/* Looks up or rasterizes GLYPH of FONT at subpixel BIN. Returns NO when the atlas is full;
 * the caller must wait for the GPU to finish with the textures, -reset, and retry. A glyph
 * that cannot be drawn at all yields an empty entry, not NO. */
- (BOOL)entryForFont:(pf_font_id)font glyph:(uint32_t)glyph bin:(int)bin entry:(PFGlyphEntry *)out;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
