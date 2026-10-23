#import "PFFont.h"

#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

/* Append-only table: ids are index + 1. Fonts stay alive for the life of the process. */
static CTFontRef *fonts;
static uint32_t font_count, font_cap;
static os_unfair_lock font_lock = OS_UNFAIR_LOCK_INIT;

static BOOL same_font(CTFontRef a, CTFontRef b) {
    if (CTFontGetSize(a) != CTFontGetSize(b)) {
        return NO;
    }
    CFStringRef na = CTFontCopyPostScriptName(a), nb = CTFontCopyPostScriptName(b);
    BOOL same = CFStringCompare(na, nb, 0) == kCFCompareEqualTo;
    CFRelease(na);
    CFRelease(nb);
    return same;
}

pf_font_id PFFontIdForCTFont(CTFontRef font) {
    os_unfair_lock_lock(&font_lock);
    for (uint32_t i = 0; i < font_count; i++) {
        if (same_font(fonts[i], font)) {
            os_unfair_lock_unlock(&font_lock);
            return i + 1;
        }
    }
    if (font_count == font_cap) {
        uint32_t cap = font_cap ? font_cap * 2 : 16;
        CTFontRef *grown = realloc(fonts, cap * sizeof *grown);
        if (!grown) {
            os_unfair_lock_unlock(&font_lock);
            return 0;
        }
        fonts = grown;
        font_cap = cap;
    }
    fonts[font_count++] = CFRetain(font);
    pf_font_id id = font_count;
    os_unfair_lock_unlock(&font_lock);
    return id;
}

CTFontRef PFFontGet(pf_font_id font) {
    os_unfair_lock_lock(&font_lock);
    CTFontRef f = font >= 1 && font <= font_count ? fonts[font - 1] : NULL;
    os_unfair_lock_unlock(&font_lock);
    return f;
}

pf_font_id pf_font_open(const char *family, float size) {
    CFStringRef name = CFStringCreateWithCString(NULL, family, kCFStringEncodingUTF8);
    if (!name) {
        return 0;
    }
    CTFontRef font = CTFontCreateWithName(name, size, NULL);
    CFStringRef got = CTFontCopyFamilyName(font);
    BOOL found = got && CFStringCompare(got, name, 0) == kCFCompareEqualTo;
    if (got) {
        CFRelease(got);
    }
    CFRelease(name);
    if (!found) {
        CFRelease(font);
        font = CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, size, NULL);
        if (!font) {
            return 0;
        }
    }
    pf_font_id id = PFFontIdForCTFont(font);
    CFRelease(font);
    return id;
}

int pf_font_metrics_get(pf_font_id font, pf_font_metrics *out) {
    CTFontRef f = PFFontGet(font);
    if (!f) {
        return -1;
    }
    UniChar zero = '0';
    CGGlyph glyph = 0;
    CGSize advance = CGSizeZero;
    if (CTFontGetGlyphsForCharacters(f, &zero, &glyph, 1)) {
        CTFontGetAdvancesForGlyphs(f, kCTFontOrientationHorizontal, &glyph, &advance, 1);
    }
    out->ascent = (float)CTFontGetAscent(f);
    out->descent = (float)CTFontGetDescent(f);
    out->leading = (float)CTFontGetLeading(f);
    out->advance = (float)advance.width;
    return 0;
}
