/* png_ink FILE X Y W H — prints the fraction of pixels in the rect darker than mid-gray. */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <ImageIO/ImageIO.h>

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 6) {
        fprintf(stderr, "usage: png_ink FILE X Y W H\n");
        return 2;
    }
    @autoreleasepool {
        NSURL *url = [NSURL fileURLWithPath:@(argv[1])];
        CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
        CGImageRef image = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (!image) {
            fprintf(stderr, "png_ink: cannot read %s\n", argv[1]);
            return 2;
        }
        size_t x = strtoul(argv[2], NULL, 10), y = strtoul(argv[3], NULL, 10);
        size_t w = strtoul(argv[4], NULL, 10), h = strtoul(argv[5], NULL, 10);
        size_t iw = CGImageGetWidth(image), ih = CGImageGetHeight(image);
        unsigned char *rgba = calloc(iw * ih, 4);
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(rgba, iw, ih, 8, iw * 4, space,
                                                 (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, iw, ih), image);
        size_t dark = 0, total = 0;
        for (size_t row = y; row < y + h && row < ih; row++) {
            for (size_t col = x; col < x + w && col < iw; col++) {
                const unsigned char *p = rgba + (row * iw + col) * 4;
                dark += (p[0] + p[1] + p[2]) / 3 < 128;
                total++;
            }
        }
        printf("%.3f\n", total ? (double)dark / (double)total : 0.0);
        CGContextRelease(ctx);
        CGColorSpaceRelease(space);
        free(rgba);
        CGImageRelease(image);
        CFRelease(src);
    }
    return 0;
}
