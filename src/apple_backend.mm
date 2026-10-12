#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <ARKit/ARKit.h>
#import <CompositorServices/CompositorServices.h>
#include "backend.hpp"
#include "composition_shader.hpp"
#include "renderer_wait.hpp"
#include <algorithm>
#include <cmath>
#include <cstdio>
#include <mach/mach_time.h>
#include <mutex>
#include <thread>
#include <chrono>
#include <simd/simd.h>

namespace {
std::mutex g_mutex;
__strong id g_renderer = nil;
__strong id<MTLCommandQueue> g_queue = nil;
ar_session_t g_trackingSession = nil;
ar_world_tracking_provider_t g_worldTracking = nil;

// Call with g_mutex held
ar_device_anchor_t queryHead(double seconds) {
    if (!g_worldTracking || ar_data_provider_get_state(g_worldTracking) != ar_data_provider_state_running)
        return nil;
    ar_device_anchor_t anchor = ar_device_anchor_create();
    if (ar_world_tracking_provider_query_device_anchor_at_timestamp(g_worldTracking, seconds, anchor)
        != ar_device_anchor_query_status_success || !ar_trackable_anchor_is_tracked(anchor))
        return nil;
    return anchor;
}
backend::HeadLocation headLocation(ar_device_anchor_t anchor);
void trackingStateChanged(void*, ar_data_providers_t, ar_data_provider_state_t state,
                          ar_error_t error, ar_data_provider_t) {
    const char* label = "unknown";
    switch (state) {
        case ar_data_provider_state_initialized: label = "initialized"; break;
        case ar_data_provider_state_running: label = "running"; break;
        case ar_data_provider_state_paused: label = "paused"; break;
        case ar_data_provider_state_stopped: label = "stopped"; break;
    }
    std::fprintf(stderr, "VisionXR: ARKit world tracking %s (error=%ld)\n", label,
                 error ? (long)ar_error_get_error_code(error) : 0L);
}
void stopTracking() {
    if (g_trackingSession) ar_session_stop(g_trackingSession);
    g_worldTracking = nil;
    g_trackingSession = nil;
}

cp_layer_renderer_t renderer() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return (cp_layer_renderer_t)g_renderer;
}

XrQuaternionf quaternion(simd_float4x4 matrix) {
    simd_quatf q = simd_quaternion(matrix);
    return { q.vector.x, q.vector.y, q.vector.z, q.vector.w };
}
backend::HeadLocation headLocation(ar_device_anchor_t anchor) {
    if (!anchor) return {};
    simd_float4x4 m = ar_anchor_get_origin_from_anchor_transform(anchor);
    return {{quaternion(m), {m.columns[3].x, m.columns[3].y, m.columns[3].z}},
            XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT |
            XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT | XR_SPACE_LOCATION_POSITION_TRACKED_BIT};
}
simd_float4x4 transform(XrPosef pose) {
    auto q = pose.orientation;
    simd_float4x4 matrix = simd_matrix4x4(simd_quaternion(q.x, q.y, q.z, q.w));
    matrix.columns[3] = {pose.position.x, pose.position.y, pose.position.z, 1};
    return matrix;
}
struct CompositionUniforms {
    simd_float4x4 clipFromLayer;
    simd_float4 uvRect;
    uint32_t slice, flags;
    uint32_t padding[2]{};
};

id<MTLDevice> g_compositionDevice = nil;
std::array<id<MTLRenderPipelineState>, 2> g_compositionPipelines{};
MTLPixelFormat g_compositionDepthFormat = MTLPixelFormatInvalid;
id<MTLDepthStencilState> g_compositionDepthState = nil;
std::array<id<MTLRenderPipelineState>, 2> compositionPipelines(id<MTLDevice> device, MTLPixelFormat depthFormat) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_compositionDevice == device && g_compositionDepthFormat == depthFormat &&
        g_compositionPipelines[0] && g_compositionPipelines[1])
        return g_compositionPipelines;
    NSError* error = nil;
    id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:compositionShader]
                                               options:nil error:&error];
    std::array<id<MTLRenderPipelineState>, 2> pipelines{};
    for (unsigned i = 0; library && i < 2; ++i) {
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"compositionVertex"];
        desc.fragmentFunction = [library newFunctionWithName:i ? @"compositionArray" : @"composition2D"];
        desc.depthAttachmentPixelFormat = depthFormat;
        auto attachment = desc.colorAttachments[0];
        attachment.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        attachment.blendingEnabled = YES;
        attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        pipelines[i] = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    }
    if (!pipelines[0] || !pipelines[1]) {
        std::fprintf(stderr, "VisionXR: composition shader/pipeline failed: %s\n", error.localizedDescription.UTF8String);
        return {};
    }
    MTLDepthStencilDescriptor* depth = [MTLDepthStencilDescriptor new];
    depth.depthCompareFunction = MTLCompareFunctionAlways; // OpenXR layer order governs visibility.
    depth.depthWriteEnabled = YES;
    g_compositionDepthState = [device newDepthStencilStateWithDescriptor:depth];
    if (!g_compositionDepthState) return {};
    g_compositionDepthFormat = depthFormat;
    g_compositionDevice = device;
    g_compositionPipelines = pipelines;
    return pipelines;
}
} // anonymous namespace

namespace backend {
void attach(void* value) {
    std::lock_guard<std::mutex> lock(g_mutex);
    stopTracking();
    g_renderer = (__bridge id)value;
    if (value && ar_world_tracking_provider_is_supported()) {
        g_trackingSession = ar_session_create();
        ar_session_set_data_provider_state_change_handler_f(g_trackingSession, nullptr, nullptr, trackingStateChanged);
        g_worldTracking = ar_world_tracking_provider_create(ar_world_tracking_configuration_create());
        ar_data_providers_t providers = ar_data_providers_create();
        ar_data_providers_add_data_provider(providers, g_worldTracking);
        ar_session_run(g_trackingSession, providers);
    } else if (value) {
        std::fprintf(stderr, "VisionXR: ARKit world tracking is unsupported; LOCAL poses will be unavailable\n");
    }
    g_queue = nil;
}
void detach() {
    std::lock_guard<std::mutex> lock(g_mutex);
    stopTracking();
    g_renderer = nil;
    g_queue = nil;
}
bool ready() { return renderer() != nullptr; }
void* device() {
    cp_layer_renderer_t r = renderer();
    return r ? (__bridge void*)cp_layer_renderer_get_device(r) : nullptr;
}
bool configureQueue(void* ptr) {
    cp_layer_renderer_t r = renderer();
    if (!r || !ptr) return false;
    id<MTLCommandQueue> queue = (__bridge id<MTLCommandQueue>)ptr;
    if (queue.device != cp_layer_renderer_get_device(r)) return false;
    auto depthFormat = cp_layer_renderer_configuration_get_depth_format(cp_layer_renderer_get_configuration(r));
    if (!compositionPipelines(queue.device, depthFormat)[0]) return false;
    std::lock_guard<std::mutex> lock(g_mutex);
    g_queue = queue;
    return true;
}
uint32_t viewCount() {
    cp_layer_renderer_t r = renderer();
    if (!r) return 2;
    return (uint32_t)cp_layer_renderer_properties_get_view_count(cp_layer_renderer_get_properties(r));
}
XrTime now() {
    static mach_timebase_info_data_t info = [] { mach_timebase_info_data_t v{}; mach_timebase_info(&v); return v; }();
    return static_cast<XrTime>((__uint128_t)mach_absolute_time() * info.numer / info.denom);
}
HeadLocation locateHead(XrTime time) {
    @autoreleasepool {
        std::lock_guard<std::mutex> lock(g_mutex);
        ar_device_anchor_t anchor = queryHead(static_cast<double>(time) / 1e9);
        return headLocation(anchor);
    }
}
XrResult createImage(uint32_t w,uint32_t h,uint32_t layers,int64_t format,void** out) {
    @autoreleasepool {
        id<MTLDevice> gpu = (__bridge id<MTLDevice>)device();
        if (!gpu || !out) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
        auto pixelFormat = (MTLPixelFormat)format;
        if (pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB) return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
        MTLTextureDescriptor* desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pixelFormat
            width:w height:h mipmapped:NO];
        desc.textureType = layers > 1 ? MTLTextureType2DArray : MTLTextureType2D;
        desc.arrayLength = layers;
        desc.storageMode = MTLStorageModePrivate;
        desc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> texture = [gpu newTextureWithDescriptor:desc];
        if (!texture) return XR_ERROR_OUT_OF_MEMORY;
        *out = (__bridge_retained void*)texture;
        return XR_SUCCESS;
    }
}
void destroyImage(void* ptr) { if (ptr) CFBridgingRelease(ptr); }
XrResult waitFrame(Frame& f) {
    cp_layer_renderer_t r = renderer();
    if (!r) return XR_ERROR_SESSION_NOT_RUNNING;
    auto state = [&] {
        switch (cp_layer_renderer_get_state(r)) {
            case cp_layer_renderer_state_running: return RendererState::Running;
            case cp_layer_renderer_state_paused: return RendererState::Paused;
            default: return RendererState::Invalidated;
        }
    };
    auto wait = [&] {
        std::fprintf(stderr, "VisionXR: compositor paused; waiting for it to run\n");
        cp_layer_renderer_wait_until_running(r);
        std::fprintf(stderr, "VisionXR: compositor wait finished (state=%u)\n",
                     (unsigned)cp_layer_renderer_get_state(r));
    };
    cp_frame_t frame = nullptr;
    for (;;) {
        if (!waitForRunning(state, wait)) return XR_ERROR_SESSION_NOT_RUNNING;
        frame = cp_layer_renderer_query_next_frame(r);
        if (frame) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
    cp_frame_timing_t timing = cp_frame_predict_timing(frame);
    if (!timing) return XR_ERROR_RUNTIME_FAILURE;
    f.opaque = frame;
    f.timing = timing;
    cp_frame_start_update(frame);
    cp_frame_end_update(frame);
   const cp_time_t optimal = cp_frame_timing_get_optimal_input_time(timing);
    f.optimalMachTicks = optimal.cp_mach_abs_time;

    const cp_time_t presentation = cp_frame_timing_get_presentation_time(timing);
    static mach_timebase_info_data_t tb = [] {
        mach_timebase_info_data_t v{};
        mach_timebase_info(&v);
        return v;
    }();

    f.displayTimeNs = static_cast<XrTime>(
        (__uint128_t)presentation.cp_mach_abs_time * tb.numer / tb.denom
    );
    return XR_SUCCESS;
}
XrResult beginFrame(Frame& f, std::vector<View>& views) {
    if (!f.opaque) return XR_ERROR_CALL_ORDER_INVALID;
    cp_time_wait_until(cp_time_t{f.optimalMachTicks});
    auto frame = (cp_frame_t)f.opaque;
    cp_frame_start_submission(frame);
    f.startedSubmission = true;
    auto drawables = cp_frame_query_drawables(frame);
    f.drawables = drawables;
    if (!drawables || cp_drawable_array_get_count(drawables) == 0) {
        f = {};
        return XR_ERROR_RUNTIME_FAILURE;
    }
    cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, 0);
    for (size_t d = 0; d < cp_drawable_array_get_count(drawables); ++d) {
        cp_drawable_t target = cp_drawable_array_get_drawable(drawables, d);
        cp_drawable_set_depth_range(target, simd_make_float2(INFINITY, 0.1f));
        auto presentation = cp_frame_timing_get_presentation_time(cp_drawable_get_frame_timing(target));
        @autoreleasepool {
            std::lock_guard<std::mutex> lock(g_mutex);
            ar_device_anchor_t anchor = queryHead(cp_time_to_cf_time_interval(presentation));
            cp_drawable_set_device_anchor(target, anchor);
            if (d == 0) f.head = headLocation(anchor);
        }
    }
    size_t n = cp_drawable_get_view_count(drawable);
    if (n == 0) {
        f = {};
        return XR_ERROR_RUNTIME_FAILURE;
    }

    views.resize(std::max<size_t>(2, n));
    for (size_t i=0; i<n; ++i) {
        cp_view_t v = cp_drawable_get_view(drawable, i);
        simd_float4 t = cp_view_get_tangents(v);
        simd_float4x4 m = cp_view_get_transform(v);
        views[i].eyeFromHead.position = {m.columns[3].x, m.columns[3].y, m.columns[3].z};
        views[i].eyeFromHead.orientation = quaternion(m);
        views[i].fov = {-atanf(t.x), atanf(t.y), atanf(t.z), -atanf(t.w)};
        views[i].available = true;
    }
    if (n == 1) views[1] = views[0];
    return XR_SUCCESS;
}
XrResult endFrame(Frame& f, const std::vector<Layer>& layers) {
    if (!f.opaque || !f.startedSubmission || !f.drawables)
        return XR_ERROR_CALL_ORDER_INVALID;

    @autoreleasepool {
        const cp_frame_t frame = (cp_frame_t)f.opaque;
        const cp_drawable_array_t drawables = (cp_drawable_array_t)f.drawables;
        const size_t drawableCount = cp_drawable_array_get_count(drawables);
        id<MTLCommandQueue> queue;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            queue = g_queue;
        }

        if (!queue) {
            id<MTLDevice> gpu = (__bridge id<MTLDevice>)device();
            queue = [gpu newCommandQueue];
        }
        if (!queue) {
            std::fprintf(stderr, "VisionXR: cannot submit drawable: no Metal command queue\n");
            f = {};
            return XR_ERROR_GRAPHICS_DEVICE_INVALID;
        }

        auto firstDrawable = cp_drawable_array_get_drawable(drawables, 0);
        auto depthFormat = cp_drawable_get_depth_texture(firstDrawable, 0).pixelFormat;
        auto pipelines = layers.empty() ? std::array<id<MTLRenderPipelineState>, 2>{}
                                        : compositionPipelines(queue.device, depthFormat);
        id<MTLDepthStencilState> depthState;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            depthState = g_compositionDepthState;
        }
        XrResult result = !layers.empty() && !pipelines[0] ? XR_ERROR_RUNTIME_FAILURE : XR_SUCCESS;
        for (size_t d = 0; d < drawableCount; ++d) {
            cp_drawable_t drawable = cp_drawable_array_get_drawable(drawables, d);
            id<MTLCommandBuffer> commands = [queue commandBuffer];
            if (!commands) {
                std::fprintf(stderr, "VisionXR: failed to allocate compositor command buffer\n");
                f = {};
                return XR_ERROR_RUNTIME_FAILURE;
            }

            const size_t textureCount = cp_drawable_get_texture_count(drawable);
            const size_t compositorViewCount = cp_drawable_get_view_count(drawable);

            for (size_t t = 0; t < textureCount; ++t) {
                id<MTLTexture> dst = cp_drawable_get_color_texture(drawable, t);
                if (!dst || !(dst.usage & MTLTextureUsageRenderTarget)) {
                    std::fprintf(stderr, "VisionXR: drawable %zu texture %zu is not a render target\n", d, t);
                    result = XR_ERROR_FEATURE_UNSUPPORTED;
                    continue;
                }
                id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, t);
                const NSUInteger slices = dst.textureType == MTLTextureType2DArray ? dst.arrayLength : 1;
                const NSUInteger depthSlices = depth.textureType == MTLTextureType2DArray ? depth.arrayLength : 1;
                if (!depth || depthSlices != slices || !(depth.usage & MTLTextureUsageRenderTarget)) {
                    std::fprintf(stderr, "VisionXR: drawable %zu has missing or incompatible depth texture %zu\n", d, t);
                    result = XR_ERROR_FEATURE_UNSUPPORTED;
                    continue;
                }
                for (NSUInteger slice = 0; slice < slices; ++slice) {
                    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
                    pass.colorAttachments[0].texture = dst;
                    pass.colorAttachments[0].slice = slice;
                    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
                    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
                    pass.depthAttachment.texture = depth;
                    pass.depthAttachment.slice = slice;
                    pass.depthAttachment.loadAction = MTLLoadActionClear;
                    pass.depthAttachment.storeAction = MTLStoreActionStore;
                    pass.depthAttachment.clearDepth = 0; // Reverse-Z background.
                    id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
                    if (encoder) [encoder endEncoding];
                    else result = XR_ERROR_RUNTIME_FAILURE;
                }
            }

            if (pipelines[0] && pipelines[1]) for (size_t eye = 0; eye < compositorViewCount; ++eye) {
                if (eye > 1) { result = XR_ERROR_FEATURE_UNSUPPORTED; continue; }
                cp_view_t view = cp_drawable_get_view(drawable, eye);
                cp_view_texture_map_t map = cp_view_get_view_texture_map(view);
                const size_t textureIndex = cp_view_texture_map_get_texture_index(map);
                const size_t slice = cp_view_texture_map_get_slice_index(map);
                const MTLViewport viewport = cp_view_texture_map_get_viewport(map);
                if (textureIndex >= textureCount) { result = XR_ERROR_RUNTIME_FAILURE; continue; }
                id<MTLTexture> dst = cp_drawable_get_color_texture(drawable, textureIndex);
                const NSUInteger dstSlices = dst.textureType == MTLTextureType2DArray ? dst.arrayLength : 1;
                if (!dst || dst.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB || slice >= dstSlices ||
                    !(dst.usage & MTLTextureUsageRenderTarget) || viewport.originX < 0 || viewport.originY < 0 ||
                    viewport.width <= 0 || viewport.height <= 0 ||
                    viewport.originX + viewport.width > dst.width || viewport.originY + viewport.height > dst.height) {
                    result = XR_ERROR_FEATURE_UNSUPPORTED; continue;
                }
                id<MTLTexture> depth = cp_drawable_get_depth_texture(drawable, textureIndex);
                const NSUInteger depthSlices = depth.textureType == MTLTextureType2DArray ? depth.arrayLength : 1;
                if (!depth || depth.pixelFormat != depthFormat || slice >= depthSlices ||
                    depth.width != dst.width || depth.height != dst.height) {
                    result = XR_ERROR_FEATURE_UNSUPPORTED; continue;
                }
                MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
                pass.depthAttachment.texture = depth;
                pass.depthAttachment.slice = slice;
                pass.depthAttachment.loadAction = MTLLoadActionLoad;
                pass.depthAttachment.storeAction = MTLStoreActionStore;
                pass.colorAttachments[0].texture = dst;
                pass.colorAttachments[0].slice = slice;
                pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
                pass.colorAttachments[0].storeAction = MTLStoreActionStore;
                id<MTLRenderCommandEncoder> encoder = [commands renderCommandEncoderWithDescriptor:pass];
                if (!encoder) { result = XR_ERROR_RUNTIME_FAILURE; continue; }
                [encoder setViewport:viewport];
                [encoder setDepthStencilState:depthState];

                const NSUInteger left = (NSUInteger)std::ceil(viewport.originX);
                const NSUInteger top = (NSUInteger)std::ceil(viewport.originY);
                const NSUInteger right = (NSUInteger)std::floor(viewport.originX + viewport.width);
                const NSUInteger bottom = (NSUInteger)std::floor(viewport.originY + viewport.height);
                if (right <= left || bottom <= top) { [encoder endEncoding]; continue; }
                [encoder setScissorRect:MTLScissorRect{left, top, right-left, bottom-top}];
                simd_float4x4 eyeFromHead = simd_inverse(cp_view_get_transform(view));
                ar_device_anchor_t anchor = cp_drawable_get_device_anchor(drawable);
                for (const auto& layer : layers) {
                    const bool quad = layer.type == Layer::Type::Quad;
                    if (quad && ((layer.eyeVisibility == XR_EYE_VISIBILITY_LEFT && eye != 0) ||
                                 (layer.eyeVisibility == XR_EYE_VISIBILITY_RIGHT && eye != 1))) continue;
                    const Copy& image = layer.images[quad ? 0 : eye];
                    id<MTLTexture> src = (__bridge id<MTLTexture>)image.texture;
                    bool array = src.textureType == MTLTextureType2DArray;
                    if (!src || (!array && src.textureType != MTLTextureType2D) ||
                        src.pixelFormat != MTLPixelFormatBGRA8Unorm_sRGB ||
                        !(src.usage & MTLTextureUsageShaderRead) || image.srcSlice >= (array ? src.arrayLength : 1)) {
                        result = XR_ERROR_FEATURE_UNSUPPORTED; continue;
                    }
                    CompositionUniforms u{};
                    u.clipFromLayer = matrix_identity_float4x4;
                    auto projection = cp_drawable_compute_projection(drawable, cp_axis_direction_convention_right_up_back, eye);
                    if (!quad) {
                        auto clip = simd_mul(projection, simd_make_float4(0, 0, -10, 1));
                        u.clipFromLayer.columns[3].z = clip.z / clip.w;
                    }
                    if (quad) {
                        if (!layer.headRelative && !anchor) continue;
                        simd_float4x4 headFromOrigin = layer.headRelative ? matrix_identity_float4x4
                            : simd_inverse(ar_anchor_get_origin_from_anchor_transform(anchor));
                        auto scale = matrix_identity_float4x4;
                        scale.columns[0].x = layer.size.width*.5f;
                        scale.columns[1].y = layer.size.height*.5f;
                        auto eyeFromQuad = simd_mul(eyeFromHead, simd_mul(headFromOrigin, transform(layer.originFromQuad)));
                        u.clipFromLayer = simd_mul(projection, simd_mul(eyeFromQuad, scale));
                    }
                    const auto& rect = image.rect;
                    u.uvRect = {(float)rect.offset.x/src.width, (float)rect.offset.y/src.height,
                                (float)rect.extent.width/src.width, (float)rect.extent.height/src.height};
                    u.slice = image.srcSlice;
                    u.flags = (uint32_t)layer.flags;
                    [encoder setRenderPipelineState:pipelines[array ? 1 : 0]];
                    [encoder setFrontFacingWinding:MTLWindingCounterClockwise];
                    [encoder setCullMode:quad ? MTLCullModeBack : MTLCullModeNone];
                    [encoder setVertexBytes:&u length:sizeof(u) atIndex:0];
                    [encoder setFragmentBytes:&u length:sizeof(u) atIndex:0];
                    [encoder setFragmentTexture:src atIndex:0];
                    [encoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
                }
                [encoder endEncoding];
            }

            cp_drawable_encode_present(drawable, commands);
            [commands addCompletedHandler:^(id<MTLCommandBuffer> completed) {
                if (completed.status == MTLCommandBufferStatusError)
                    std::fprintf(stderr, "VisionXR: compositor GPU command failed: %s\n",
                                 completed.error.localizedDescription.UTF8String);
            }];
            [commands commit];
        }
        cp_frame_end_submission(frame);
        f = {};
        return result;
    }
}
} // namespace backend

extern "C" {
void xrvision_attach_layer_renderer(void* ptr) { backend::attach(ptr); }
void xrvision_detach_layer_renderer(void) { backend::detach(); }
}
