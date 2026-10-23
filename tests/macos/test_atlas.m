/* Glyph atlas: caching, empty glyphs, color pages, scale changes and the full -> reset path.
 * Needs a Metal device (label macos), no window. */

#import <CoreText/CoreText.h>
#import <Metal/Metal.h>

#import "PFFont.h"
#import "PFGlyphAtlas.h"

#include "pf_test.h"

static CGGlyph glyph_for(pf_font_id font, UniChar c) {
    CGGlyph g = 0;
    CTFontGetGlyphsForCharacters(PFFontGet(font), &c, &g, 1);
    return g;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "no Metal device\n");
            return 1;
        }
        PFGlyphAtlas *atlas = [[PFGlyphAtlas alloc] initWithDevice:device];
        PF_CHECK(atlas != nil);
        [atlas setScale:2];
        pf_font_id mono = pf_font_open("Menlo", 14);
        PF_CHECK(mono != 0);
        PF_CHECK(pf_font_open("Menlo", 14) == mono); /* same family and size: same id */

        PFGlyphEntry a, again, space, binned;
        PF_CHECK([atlas entryForFont:mono glyph:glyph_for(mono, 'A') bin:0 entry:&a]);
        PF_CHECK(a.w > 0 && a.h > 0 && a.page == PFAtlasPageGray);
        PF_CHECK(a.oy > 0); /* box top is above the baseline */
        PF_CHECK([atlas entryForFont:mono glyph:glyph_for(mono, 'A') bin:0 entry:&again]);
        PF_CHECK(again.x == a.x && again.y == a.y); /* cached, not re-rasterized */
        PF_CHECK([atlas entryForFont:mono glyph:glyph_for(mono, 'A') bin:2 entry:&binned]);
        PF_CHECK(binned.x != a.x || binned.y != a.y); /* subpixel bins are separate */
        PF_CHECK([atlas entryForFont:mono glyph:glyph_for(mono, ' ') bin:0 entry:&space]);
        PF_CHECK(space.w == 0);
        PF_CHECK([atlas entryForFont:9999 glyph:1 bin:0 entry:&space] && space.w == 0);

        /* Emoji go to the color page. */
        CTFontRef emojiFont = CTFontCreateWithName(CFSTR("Apple Color Emoji"), 14, NULL);
        pf_font_id emoji = PFFontIdForCTFont(emojiFont);
        CFRelease(emojiFont);
        UniChar smile[2] = {0xD83D, 0xDE00};
        CGGlyph sg[2] = {0};
        CTFontGetGlyphsForCharacters(PFFontGet(emoji), smile, sg, 2);
        PFGlyphEntry e;
        PF_CHECK([atlas entryForFont:emoji glyph:sg[0] bin:0 entry:&e]);
        PF_CHECK(e.page == PFAtlasPageColor && e.w > 0);

        /* Fill the gray page with huge glyphs until it reports full, then reset and retry. */
        pf_font_id huge = pf_font_open("Menlo", 200);
        CFIndex count = CTFontGetGlyphCount(PFFontGet(huge));
        BOOL full = NO;
        CGGlyph failed = 0;
        for (CGGlyph g = 1; g < count && !full; g++) {
            PFGlyphEntry ignored;
            if (![atlas entryForFont:huge glyph:g bin:0 entry:&ignored]) {
                full = YES;
                failed = g;
            }
        }
        PF_CHECK(full);
        [atlas reset];
        PFGlyphEntry retry;
        PF_CHECK([atlas entryForFont:huge glyph:failed bin:0 entry:&retry]);
        PF_CHECK(retry.x == 0 && retry.y == 0); /* first glyph of an empty atlas */

        /* A scale change empties the atlas: 'A' is rasterized afresh, at the new size. */
        [atlas setScale:1];
        PFGlyphEntry small;
        PF_CHECK([atlas entryForFont:mono glyph:glyph_for(mono, 'A') bin:0 entry:&small]);
        PF_CHECK(small.x == 0 && small.y == 0 && small.h < a.h);
    }
    return PF_TEST_RESULT();
}
