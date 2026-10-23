#include <metal_stdlib>
using namespace metal;

struct TextVertexOut {
    float4 position [[position]];
    float2 uv;
};

// One quad as a 4-vertex triangle strip; rect is (x0, y0, x1, y1) in normalized device space.
vertex TextVertexOut pf_text_vertex(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    float2 uv = float2(vid & 1, vid >> 1);
    TextVertexOut out;
    out.position = float4(mix(rect.x, rect.z, uv.x), mix(rect.y, rect.w, uv.y), 0.0, 1.0);
    out.uv = uv;
    return out;
}

// Coverage-only texture (R8) tinted with a premultiplied output color.
fragment float4 pf_text_fragment(TextVertexOut in [[stage_in]],
                                 texture2d<float> coverage [[texture(0)]],
                                 constant float4 &color [[buffer(0)]]) {
    constexpr sampler nearest(filter::nearest);
    float a = coverage.sample(nearest, in.uv).r * color.a;
    return float4(color.rgb * a, a);
}
