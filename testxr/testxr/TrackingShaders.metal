#include <metal_stdlib>
using namespace metal;

struct SceneVertex { float4 position; float4 color; };
struct RasterVertex { float4 position [[position]]; float4 color; };

vertex RasterVertex trackingVertex(uint index [[vertex_id]],
                                  const device SceneVertex* vertices [[buffer(0)]],
                                  constant float4x4& clipFromLocal [[buffer(1)]]) {
    return {clipFromLocal * vertices[index].position, vertices[index].color};
}
fragment float4 trackingFragment(RasterVertex in [[stage_in]]) {
    return in.color;
}

struct PanelVertex { float4 position [[position]]; float2 uv; };
vertex PanelVertex panelVertex(uint index [[vertex_id]]) {
    const float2 p[] = {float2(-1,-1),float2(1,-1),float2(-1,1),float2(1,1)};
    return {float4(p[index],0,1), float2((p[index].x+1)*.5,(1-p[index].y)*.5)};
}
fragment float4 panelFragment(PanelVertex in [[stage_in]]) {
    float2 uv = in.uv;
    float edge = min(min(uv.x,1-uv.x),min(uv.y,1-uv.y));
    bool border = edge < .025;
    float checker = fmod(floor(uv.x*12)+floor(uv.y*6),2.0);
    float3 color = border ? float3(1,.7,.12) : mix(float3(.02,.18,.3),float3(.05,.6,.8),checker);
    // Transparent circular cutout makes source-alpha composition easy to inspect.
    float alpha = distance(uv,float2(.5,.5)) < .14 ? 0 : (border ? 1 : .72);
    return float4(color,alpha); // Straight alpha; the OpenXR layer requests premultiplication.
}
