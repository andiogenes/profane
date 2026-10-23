#import "PFShaper.h"

#import <CoreText/CoreText.h>

#import "PFFont.h"

#include <stdlib.h>

static float shape(void *ctx, uint32_t font, const uint32_t *cps, size_t n, pf_shaped *out) {
    (void)ctx;
    CTFontRef base = PFFontGet(font);
    if (!base || n == 0) {
        return 0;
    }
    /* UTF-16 for Core Text, remembering which character each code unit came from. */
    UniChar *units = malloc(n * 2 * sizeof *units);
    uint32_t *owner = malloc(n * 2 * sizeof *owner);
    CFIndex len = 0;
    for (size_t i = 0; i < n; i++) {
        uint32_t cp = cps[i];
        if (cp >= 0x10000) {
            cp -= 0x10000;
            units[len] = (UniChar)(0xD800 + (cp >> 10));
            owner[len++] = (uint32_t)i;
            units[len] = (UniChar)(0xDC00 + (cp & 0x3FF));
        } else {
            units[len] = (UniChar)cp;
        }
        owner[len++] = (uint32_t)i;
    }
    CFStringRef str = CFStringCreateWithCharactersNoCopy(NULL, units, len, kCFAllocatorNull);
    const void *keys[] = {kCTFontAttributeName};
    const void *values[] = {base};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CFAttributedStringRef astr = CFAttributedStringCreate(NULL, str, attrs);
    CTLineRef line = CTLineCreateWithAttributedString(astr);

    CFArrayRef runs = CTLineGetGlyphRuns(line);
    for (CFIndex r = 0; r < CFArrayGetCount(runs); r++) {
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CTFontRef runFont = CFDictionaryGetValue(CTRunGetAttributes(run), kCTFontAttributeName);
        uint32_t fid = runFont ? PFFontIdForCTFont(runFont) : font;
        CFIndex count = CTRunGetGlyphCount(run);
        if (count <= 0) {
            continue;
        }
        CGGlyph *glyphs = malloc((size_t)count * sizeof *glyphs);
        CGPoint *pos = malloc((size_t)count * sizeof *pos);
        CFIndex *index = malloc((size_t)count * sizeof *index);
        CTRunGetGlyphs(run, CFRangeMake(0, count), glyphs);
        CTRunGetPositions(run, CFRangeMake(0, count), pos);
        CTRunGetStringIndices(run, CFRangeMake(0, count), index);
        for (CFIndex g = 0; g < count; g++) {
            uint32_t cluster = index[g] >= 0 && index[g] < len ? owner[index[g]] : 0;
            pf_shaped_push(out, fid, glyphs[g], (float)pos[g].x, cluster);
        }
        free(glyphs);
        free(pos);
        free(index);
    }
    float width = (float)CTLineGetTypographicBounds(line, NULL, NULL, NULL);
    CFRelease(line);
    CFRelease(astr);
    CFRelease(attrs);
    CFRelease(str);
    free(units);
    free(owner);
    return width;
}

static float cell_width(void *ctx, uint32_t font) {
    (void)ctx;
    pf_font_metrics m;
    return pf_font_metrics_get(font, &m) == 0 ? m.advance : 0;
}

pf_shaper PFCoreTextShaper(void) {
    return (pf_shaper){NULL, shape, cell_width};
}
