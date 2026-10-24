/* The clip primitive (pf_display_clip): rendered offscreen through the Metal renderer, then read
 * back from the snapshot PNG. Needs a Metal device (label macos), no window. */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

#import "PFMetalRenderer.h"

#include "pf_display.h"
#include "pf_test.h"

/* The pixel at X, Y of the PNG as 0xRRGGBB. */
static uint32_t pixel(CGImageRef image, size_t x, size_t y) {
    size_t w = CGImageGetWidth(image), h = CGImageGetHeight(image);
    unsigned char *rgba = calloc(w * h, 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(rgba, w, h, 8, w * 4, space,
                                             (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), image);
    const unsigned char *p = rgba + (y * w + x) * 4;
    uint32_t c = (uint32_t)p[0] << 16 | (uint32_t)p[1] << 8 | p[2];
    CGContextRelease(ctx);
    CGColorSpaceRelease(space);
    free(rgba);
    return c;
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (!device) {
            fprintf(stderr, "no Metal device\n");
            return 1;
        }
        NSMutableArray<CAMetalLayer *> *layers = [NSMutableArray array];
        for (int i = 0; i < PF_LAYER_COUNT; i++) {
            [layers addObject:[CAMetalLayer layer]];
        }
        PFMetalRenderer *r = [[PFMetalRenderer alloc] initWithDevice:device layers:layers];
        PF_CHECK(r != nil);
        if (!r) {
            return 1;
        }

        pf_display *d = pf_display_new(40, 20, 2, 0xFFFFFFFF); /* 80 x 40 pixels */
        pf_display_clip(d, 10, 5, 10, 10);
        pf_display_rect(d, 0, 0, 40, 20, 0xFF0000FF);
        pf_display_unclip(d);
        pf_display_rect(d, 30, 0, 5, 5, 0x0000FFFF);
        pf_display_finish(d);
        pf_renderer_submit(r.renderer, PF_LAYER_BASE, d);
        pf_display_release(d);

        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:@"pf-clip.png"];
        PF_CHECK([r writeSnapshotToURL:[NSURL fileURLWithPath:path]]);
        CGImageSourceRef src =
            CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], NULL);
        CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        PF_CHECK(image != NULL);
        if (image) {
            PF_CHECK(pixel(image, 30, 20) == 0xFF0000);  /* inside the clip: red */
            PF_CHECK(pixel(image, 20, 10) == 0xFF0000);  /* its top-left pixel */
            PF_CHECK(pixel(image, 39, 19) == 0xFF0000);  /* its bottom-right pixel */
            PF_CHECK(pixel(image, 19, 20) == 0xFFFFFF);  /* left of it: not drawn */
            PF_CHECK(pixel(image, 40, 20) == 0xFFFFFF);  /* right of it */
            PF_CHECK(pixel(image, 30, 9) == 0xFFFFFF);   /* above it */
            PF_CHECK(pixel(image, 30, 30) == 0xFFFFFF);  /* below it */
            PF_CHECK(pixel(image, 65, 5) == 0x0000FF);   /* after the clip ended: drawn */
            CGImageRelease(image);
        }
        if (src) {
            CFRelease(src);
        }
        [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    }
    return PF_TEST_RESULT();
}
