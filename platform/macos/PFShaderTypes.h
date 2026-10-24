#ifndef PF_SHADER_TYPES_H
#define PF_SHADER_TYPES_H

/* Shared by Shaders.metal and the Objective-C renderer. */

#ifdef __METAL_VERSION__
typedef float4 pf_float4;
typedef uint pf_uint;
#else
#include <simd/simd.h>
typedef simd_float4 pf_float4;
typedef uint32_t pf_uint;
#endif

enum {
    PF_QUAD_RECT = 0,
    PF_QUAD_GLYPH_GRAY = 1,
    PF_QUAD_GLYPH_COLOR = 2,
    PF_QUAD_ROUND_RECT = 3, /* uv: half width, half height, radius, outline width (pixels) */
    PF_QUAD_SHADOW = 4,     /* uv: half width, half height, radius, blur sigma (pixels) */
};

typedef struct PFQuadInstance {
    pf_float4 rect; /* x, y, w, h in pixels, origin top-left */
    pf_float4 uv;   /* u0, v0, u1, v1 normalized */
    pf_uint color;  /* sRGB 0xRRGGBBAA, straight alpha */
    pf_uint mode;
    pf_uint pad[2];
} PFQuadInstance;

#endif
