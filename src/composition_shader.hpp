#pragma once

inline constexpr const char* compositionShader = R"metal(
#include <metal_stdlib>
using namespace metal;
struct Uniforms { float4x4 clipFromLayer; float4 uvRect; uint slice; uint flags; uint2 padding; };
struct Vertex { float4 position [[position]]; float2 uv; };
vertex Vertex compositionVertex(uint index [[vertex_id]], constant Uniforms& u [[buffer(0)]]) {
    const float2 corners[] = {float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1)};
    float2 p = corners[index];
    return {u.clipFromLayer * float4(p,0,1), u.uvRect.xy + float2((p.x+1)*.5,(1-p.y)*.5)*u.uvRect.zw};
}
float4 sourceColor(float4 color, uint flags) {
    if (!(flags & 2)) color.a = 1; // XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT
    else if (flags & 4) color.rgb *= color.a; // XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT
    return color;
}
struct Fragment { float4 color [[color(0)]]; float depth [[depth(any)]]; };
Fragment composedPixel(float4 sample, uint flags, float depth) {
    float4 color = sourceColor(sample, flags);
    // A transparent overlay must preserve both the underlying colour and depth.
    if (color.a == 0) discard_fragment();
    return {color, depth};
}
fragment Fragment composition2D(Vertex in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                             texture2d<float> image [[texture(0)]]) {
    constexpr sampler filter(coord::normalized, address::clamp_to_edge, filter::linear);
    // Clamp to texel centres inside the submitted subrect to avoid atlas bleed.
    float2 halfTexel = .5/float2(image.get_width(),image.get_height());
    float2 uv = clamp(in.uv, u.uvRect.xy+halfTexel, u.uvRect.xy+u.uvRect.zw-halfTexel);
    return composedPixel(image.sample(filter,uv), u.flags, in.position.z);
}
fragment Fragment compositionArray(Vertex in [[stage_in]], constant Uniforms& u [[buffer(0)]],
                                texture2d_array<float> image [[texture(0)]]) {
    constexpr sampler filter(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 halfTexel = .5/float2(image.get_width(),image.get_height());
    float2 uv = clamp(in.uv, u.uvRect.xy+halfTexel, u.uvRect.xy+u.uvRect.zw-halfTexel);
    return composedPixel(image.sample(filter,uv,u.slice), u.flags, in.position.z);
}
)metal";
