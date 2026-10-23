#include <metal_stdlib>
using namespace metal;

#include "PFShaderTypes.h"

struct QuadOut {
    float4 position [[position]];
    float2 uv;
    float4 color; // premultiplied
    uint mode [[flat]];
};

// One instance per rect or glyph, drawn as a 4-vertex triangle strip in pixel space.
vertex QuadOut pf_quad_vertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                              const device PFQuadInstance *quads [[buffer(0)]],
                              constant float2 &viewport [[buffer(1)]]) {
    PFQuadInstance q = quads[iid];
    float2 corner = float2(vid & 1, vid >> 1);
    float2 px = q.rect.xy + corner * q.rect.zw;
    QuadOut out;
    out.position = float4(px.x / viewport.x * 2.0 - 1.0, 1.0 - px.y / viewport.y * 2.0, 0.0, 1.0);
    out.uv = mix(q.uv.xy, q.uv.zw, corner);
    uint c = q.color;
    float4 rgba = float4((c >> 24) & 0xFF, (c >> 16) & 0xFF, (c >> 8) & 0xFF, c & 0xFF) / 255.0;
    out.color = float4(rgba.rgb * rgba.a, rgba.a);
    out.mode = q.mode;
    return out;
}

fragment float4 pf_quad_fragment(QuadOut in [[stage_in]], texture2d<float> gray [[texture(0)]],
                                 texture2d<float> color [[texture(1)]]) {
    constexpr sampler nearest(filter::nearest);
    switch (in.mode) {
    case PF_QUAD_GLYPH_GRAY:
        return in.color * gray.sample(nearest, in.uv).r;
    case PF_QUAD_GLYPH_COLOR:
        return color.sample(nearest, in.uv) * in.color.a;
    default:
        return in.color;
    }
}
