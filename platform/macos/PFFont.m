#import "PFFont.h"

#import <Foundation/Foundation.h>

#include <os/lock.h>
#include <stdlib.h>
#include <string.h>

/* Append-only table: ids are index + 1. Fonts stay alive for the life of the process. */
static CTFontRef *fonts;
static uint32_t font_count, font_cap;
static os_unfair_lock font_lock = OS_UNFAIR_LOCK_INIT;

/* Same face, size and OpenType feature settings. */
static BOOL same_font(CTFontRef a, CTFontRef b) {
    if (CTFontGetSize(a) != CTFontGetSize(b)) {
        return NO;
    }
    CFStringRef na = CTFontCopyPostScriptName(a), nb = CTFontCopyPostScriptName(b);
    BOOL same = CFStringCompare(na, nb, 0) == kCFCompareEqualTo;
    CFRelease(na);
    CFRelease(nb);
    if (same) {
        CFTypeRef fa = CTFontCopyAttribute(a, kCTFontFeatureSettingsAttribute);
        CFTypeRef fb = CTFontCopyAttribute(b, kCTFontFeatureSettingsAttribute);
        same = (!fa && !fb) || (fa && fb && CFEqual(fa, fb));
        if (fa) {
            CFRelease(fa);
        }
        if (fb) {
            CFRelease(fb);
        }
    }
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

pf_font_id pf_font_open_styled(const char *family, float size, int bold, int italic) {
    pf_font_id base = family ? pf_font_open(family, size)
                             : PFFontIdForCTFont((CTFontRef)CFAutorelease(
                                   CTFontCreateUIFontForLanguage(kCTFontUIFontUserFixedPitch, size, NULL)));
    if (!base || (!bold && !italic)) {
        return base;
    }
    CTFontSymbolicTraits traits = (bold ? kCTFontTraitBold : 0) | (italic ? kCTFontTraitItalic : 0);
    CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(PFFontGet(base), size, NULL, traits, traits);
    if (!styled) {
        return base; /* the family has no such style: keep the regular face */
    }
    pf_font_id id = PFFontIdForCTFont(styled);
    CFRelease(styled);
    return id;
}

/* "calt=0,liga=0" -> OpenType feature settings for a font descriptor. */
static CFArrayRef create_features(const char *spec) {
    CFMutableArrayRef settings = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    NSString *all = @(spec);
    for (NSString *item in [all componentsSeparatedByString:@","]) {
        NSArray<NSString *> *kv = [item componentsSeparatedByString:@"="];
        NSString *tag = [kv[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (tag.length != 4) {
            continue;
        }
        int value = kv.count > 1 ? kv[1].intValue : 1;
        NSDictionary *setting = @{
            (__bridge id)kCTFontOpenTypeFeatureTag : tag,
            (__bridge id)kCTFontOpenTypeFeatureValue : @(value),
        };
        CFArrayAppendValue(settings, (__bridge CFDictionaryRef)setting);
    }
    return settings;
}

pf_font_id pf_font_open_ex(const char *family, float size, int bold, int italic,
                           const char *features) {
    pf_font_id base;
    if (family && strcmp(family, "system-ui") == 0) {
        CTFontRef ui = CTFontCreateUIFontForLanguage(kCTFontUIFontSystem, size, NULL);
        base = ui ? PFFontIdForCTFont(ui) : 0;
        if (ui) {
            CFRelease(ui);
        }
        if (base && (bold || italic)) {
            CTFontSymbolicTraits t = (bold ? kCTFontTraitBold : 0) | (italic ? kCTFontTraitItalic : 0);
            CTFontRef styled = CTFontCreateCopyWithSymbolicTraits(PFFontGet(base), size, NULL, t, t);
            if (styled) {
                base = PFFontIdForCTFont(styled);
                CFRelease(styled);
            }
        }
    } else {
        base = pf_font_open_styled(family, size, bold, italic);
    }
    if (!base || !features || !*features) {
        return base;
    }
    CFArrayRef settings = create_features(features);
    const void *keys[] = {kCTFontFeatureSettingsAttribute};
    const void *values[] = {settings};
    CFDictionaryRef attrs = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                               &kCFTypeDictionaryValueCallBacks);
    CTFontDescriptorRef desc = CTFontDescriptorCreateWithAttributes(attrs);
    CTFontRef featured = CTFontCreateCopyWithAttributes(PFFontGet(base), size, NULL, desc);
    pf_font_id id = featured ? PFFontIdForCTFont(featured) : base;
    if (featured) {
        CFRelease(featured);
    }
    CFRelease(desc);
    CFRelease(attrs);
    CFRelease(settings);
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
