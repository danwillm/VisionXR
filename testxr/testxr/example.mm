// Headset tracking demo: a LOCAL-space scene viewed through OpenXR eye poses.
#import <Metal/Metal.h>
#include <simd/simd.h>
#include <cmath>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <visionxr/host.h>
#include <cstdio>
#include <vector>

#define XR_CHECK(e) do { XrResult result=(e); if (XR_FAILED(result)) { \
    std::fprintf(stderr, "VisionXR example: %s failed: %d\n",#e,(int)result); return; } } while(0)

namespace {
constexpr XrSpaceLocationFlags validHead = XR_SPACE_LOCATION_POSITION_VALID_BIT |
                                         XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
constexpr XrViewStateFlags validViews = XR_VIEW_STATE_POSITION_VALID_BIT |
                                       XR_VIEW_STATE_ORIENTATION_VALID_BIT;

// Finish an active compositor frame and release OpenXR objects on every exit.
struct ExampleResources {
    XrInstance instance{};
    XrSession session{};
    XrSwapchain swapchain{}, quadSwapchain{};
    XrSpace local{}, view{};
    bool running = false, frameActive = false, acquired = false;
    bool quadAcquired = false;
    XrTime displayTime = 0;
    ~ExampleResources() {
        if (acquired) {
            XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            wait.timeout = XR_INFINITE_DURATION;
            xrWaitSwapchainImage(swapchain, &wait);
            XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            xrReleaseSwapchainImage(swapchain, &release);
        }
        if (quadAcquired) {
            XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; wait.timeout = XR_INFINITE_DURATION;
            xrWaitSwapchainImage(quadSwapchain, &wait);
            XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            xrReleaseSwapchainImage(quadSwapchain, &release);
        }
        if (frameActive) {
            XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
            end.displayTime = displayTime;
            end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
            xrEndFrame(session, &end);
        }
        if (view) xrDestroySpace(view);
        if (local) xrDestroySpace(local);
        if (swapchain) xrDestroySwapchain(swapchain);
        if (quadSwapchain) xrDestroySwapchain(quadSwapchain);
        if (running) xrEndSession(session);
        if (session) xrDestroySession(session);
        if (instance) xrDestroyInstance(instance);
    }
};

simd_float4x4 clipFromEye(XrFovf fov) {
    const float l = std::tan(fov.angleLeft), r = std::tan(fov.angleRight);
    const float d = std::tan(fov.angleDown), u = std::tan(fov.angleUp);
    constexpr float near = 0.05f, far = 30.f;
    // Asymmetric OpenXR frustum, forward -Z, Metal depth range [0, 1].
    simd_float4x4 matrix{};
    matrix.columns[0] = {2/(r-l), 0, 0, 0};
    matrix.columns[1] = {0, 2/(u-d), 0, 0};
    matrix.columns[2] = {(r+l)/(r-l), (u+d)/(u-d), -far/(far-near), -1};
    matrix.columns[3] = {0, 0, -far*near/(far-near), 0};
    return matrix;
}
simd_float4x4 eyeFromLocal(XrPosef pose) {
    auto q = pose.orientation;
    simd_float4x4 localFromEye = simd_matrix4x4(simd_quaternion(q.x, q.y, q.z, q.w));
    localFromEye.columns[3] = {pose.position.x, pose.position.y, pose.position.z, 1};
    return simd_inverse(localFromEye);
}

struct SceneVertex { simd_float4 position, color; };
struct TrackingScene {
    id<MTLRenderPipelineState> pipeline;
    id<MTLDepthStencilState> depthState;
    id<MTLTexture> depth;
    id<MTLBuffer> vertices;
    NSUInteger vertexCount = 0;

    bool initialize(id<MTLDevice> device, uint32_t width, uint32_t height) {
        id<MTLLibrary> library = [device newDefaultLibrary];
        MTLRenderPipelineDescriptor* desc = [MTLRenderPipelineDescriptor new];
        desc.vertexFunction = [library newFunctionWithName:@"trackingVertex"];
        desc.fragmentFunction = [library newFunctionWithName:@"trackingFragment"];
        if (!desc.vertexFunction || !desc.fragmentFunction) {
            std::fprintf(stderr, "VisionXR test: missing TrackingShaders.metal functions\n");
            return false;
        }
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        NSError* error = nil;
        pipeline = [device newRenderPipelineStateWithDescriptor:desc error:&error];
        if (!pipeline) {
            std::fprintf(stderr, "VisionXR test: pipeline failed: %s\n", error.localizedDescription.UTF8String);
            return false;
        }
        MTLDepthStencilDescriptor* depthDesc = [MTLDepthStencilDescriptor new];
        depthDesc.depthCompareFunction = MTLCompareFunctionLess;
        depthDesc.depthWriteEnabled = YES;
        depthState = [device newDepthStencilStateWithDescriptor:depthDesc];
        MTLTextureDescriptor* texture = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
            width:width height:height mipmapped:NO];
        texture.textureType = MTLTextureType2DArray;
        texture.arrayLength = 2;
        texture.storageMode = MTLStorageModePrivate;
        texture.usage = MTLTextureUsageRenderTarget;
        depth = [device newTextureWithDescriptor:texture];
        std::vector<SceneVertex> mesh;
        auto box = [&](simd_float3 center, simd_float3 halfSize, simd_float4 color) {
            const simd_float3 corners[] = {{-1,-1,-1}, {1,-1,-1}, {1,1,-1}, {-1,1,-1},
                                          {-1,-1,1}, {1,-1,1}, {1,1,1}, {-1,1,1}};
            const unsigned faces[][6] = {{4,5,6,4,6,7}, {1,0,3,1,3,2}, {0,4,7,0,7,3},
                                         {5,1,2,5,2,6}, {3,7,6,3,6,2}, {0,1,5,0,5,4}};
            const float shade[] = {1, .55f, .7f, .85f, 1.15f, .45f};
            for (unsigned face = 0; face < 6; ++face) {
                auto tint = color * shade[face]; tint.w = 1;
                for (unsigned index : faces[face]) {
                    auto p = center + corners[index] * halfSize;
                    mesh.push_back({{p.x,p.y,p.z,1}, tint});
                }
            }
        };
        // Fixed metre-scale objects make translation and stereo parallax visible.
        box(simd_make_float3(0,-.2f,-2), simd_make_float3(.25f,.25f,.25f), simd_make_float4(1,.35f,.08f,1));
        box(simd_make_float3(-.9f,-.35f,-2.8f), simd_make_float3(.18f,.18f,.18f), simd_make_float4(.08f,.55f,1,1));
        box(simd_make_float3(.9f,0,-3.2f), simd_make_float3(.3f,.3f,.3f), simd_make_float4(.15f,.85f,.3f,1));
        // This grid is 0.8 m below the initial head, not a detected physical floor.
        for (int i = -4; i <= 4; ++i) {
            box(simd_make_float3(i*.5f,-.8f,-2.5f), simd_make_float3(.004f,.004f,2), simd_make_float4(.2f,.25f,.3f,1));
            box(simd_make_float3(0,-.8f,-2.5f+i*.5f), simd_make_float3(2,.004f,.004f), simd_make_float4(.2f,.25f,.3f,1));
        }
        vertexCount = mesh.size();
        vertices = [device newBufferWithBytes:mesh.data() length:mesh.size()*sizeof(SceneVertex)
            options:MTLResourceStorageModeShared];
        return depthState && depth && vertices;
    }

    bool render(id<MTLCommandBuffer> cmd, id<MTLTexture> color, const XrView* views) {
        for (unsigned eye = 0; eye < 2; ++eye) {
            MTLRenderPassDescriptor* pass = [MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture = color;
            pass.colorAttachments[0].slice = eye;
            pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            pass.colorAttachments[0].clearColor = MTLClearColorMake(.015,.02,.03,1);
            pass.depthAttachment.texture = depth;
            pass.depthAttachment.slice = eye;
            pass.depthAttachment.loadAction = MTLLoadActionClear;
            pass.depthAttachment.storeAction = MTLStoreActionDontCare;
            pass.depthAttachment.clearDepth = 1;
            id<MTLRenderCommandEncoder> encoder = [cmd renderCommandEncoderWithDescriptor:pass];
            if (!encoder) return false;
            simd_float4x4 matrix = simd_mul(clipFromEye(views[eye].fov), eyeFromLocal(views[eye].pose));
            [encoder setRenderPipelineState:pipeline];
            [encoder setDepthStencilState:depthState];
            [encoder setVertexBuffer:vertices offset:0 atIndex:0];
            [encoder setVertexBytes:&matrix length:sizeof(matrix) atIndex:1];
            [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertexCount];
            [encoder endEncoding];
        }
        return true;
    }
};
} // namespace

extern "C" void xrvision_run_example() {
    std::fprintf(stderr, "VisionXR test: starting OpenXR demo\n");
    ExampleResources resources;
    const char* extensions[]={XR_KHR_METAL_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo ici{XR_TYPE_INSTANCE_CREATE_INFO};
    std::snprintf(ici.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "VisionXR Test");
    ici.applicationInfo.apiVersion=XR_CURRENT_API_VERSION;
    ici.enabledExtensionCount=1;
    ici.enabledExtensionNames=extensions;
    auto& instance = resources.instance;
    XR_CHECK(xrCreateInstance(&ici,&instance));
    XrSystemGetInfo gi{XR_TYPE_SYSTEM_GET_INFO};
    gi.formFactor=XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    XrSystemId system{};
    XR_CHECK(xrGetSystem(instance,&gi,&system));
    XrGraphicsRequirementsMetalKHR gpu{XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
    XR_CHECK(xrGetMetalGraphicsRequirementsKHR(instance,system,&gpu));
    id<MTLDevice> device = (__bridge id<MTLDevice>)gpu.metalDevice;
    id<MTLCommandQueue> queue=[device newCommandQueue];
    XrGraphicsBindingMetalKHR binding{XR_TYPE_GRAPHICS_BINDING_METAL_KHR};
    binding.commandQueue=(__bridge void*)queue;
    XrSessionCreateInfo sci{XR_TYPE_SESSION_CREATE_INFO};
    sci.systemId=system; sci.next=&binding;
    auto& session = resources.session;
    XR_CHECK(xrCreateSession(instance,&sci,&session));
    XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};
    bi.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    XR_CHECK(xrBeginSession(session,&bi));
    resources.running = true;

    XrViewConfigurationView configs[2]={{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
    uint32_t count=0;
    XR_CHECK(xrEnumerateViewConfigurationViews(instance,system,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                               2,&count,configs));
    const uint32_t width=configs[0].recommendedImageRectWidth;
    const uint32_t height=configs[0].recommendedImageRectHeight;
    XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    ci.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    ci.format=MTLPixelFormatBGRA8Unorm_sRGB; ci.sampleCount=1;
    ci.width=width;ci.height=height;ci.faceCount=1;ci.arraySize=2;ci.mipCount=1;
    auto& sc = resources.swapchain;
    XR_CHECK(xrCreateSwapchain(session,&ci,&sc));
    uint32_t imageCount=0;
    XR_CHECK(xrEnumerateSwapchainImages(sc,0,&imageCount,nullptr));
    std::vector<XrSwapchainImageMetalKHR> images(imageCount);
    for(auto& image:images) image.type=XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
    XR_CHECK(xrEnumerateSwapchainImages(sc,imageCount,&imageCount,
                                       (XrSwapchainImageBaseHeader*)images.data()));
    XrReferenceSpaceCreateInfo rci{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    rci.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_LOCAL;
    rci.poseInReferenceSpace.orientation.w=1;
    auto& space = resources.local;
    XR_CHECK(xrCreateReferenceSpace(session,&rci,&space));
    rci.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    XR_CHECK(xrCreateReferenceSpace(session,&rci,&resources.view));
    TrackingScene scene;
    if (!scene.initialize(device, width, height)) return;
    // Render a static alpha-textured panel once; reuse its released image in
    // two composition layers. This content is separate from the projection scene.
    auto quadInfo = ci; quadInfo.width = 512; quadInfo.height = 256; quadInfo.arraySize = 1;
    XR_CHECK(xrCreateSwapchain(session, &quadInfo, &resources.quadSwapchain));
    uint32_t quadImageCount = 0;
    XR_CHECK(xrEnumerateSwapchainImages(resources.quadSwapchain, 0, &quadImageCount, nullptr));
    std::vector<XrSwapchainImageMetalKHR> quadImages(quadImageCount);
    for (auto& image : quadImages) image.type = XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
    XR_CHECK(xrEnumerateSwapchainImages(resources.quadSwapchain,quadImageCount,&quadImageCount,
                                      reinterpret_cast<XrSwapchainImageBaseHeader*>(quadImages.data())));
    id<MTLLibrary> library = [device newDefaultLibrary];
    MTLRenderPipelineDescriptor* panelDesc = [MTLRenderPipelineDescriptor new];
    panelDesc.vertexFunction = [library newFunctionWithName:@"panelVertex"];
    panelDesc.fragmentFunction = [library newFunctionWithName:@"panelFragment"];
    panelDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    NSError* error = nil;
    id<MTLRenderPipelineState> panelPipeline = [device newRenderPipelineStateWithDescriptor:panelDesc error:&error];
    if (!panelPipeline) {
        std::fprintf(stderr,"VisionXR test: panel pipeline failed: %s\n",error.localizedDescription.UTF8String);
        return;
    }
    uint32_t quadImageIndex = 0;
    XrSwapchainImageAcquireInfo panelAcquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
    XR_CHECK(xrAcquireSwapchainImage(resources.quadSwapchain,&panelAcquire,&quadImageIndex));
    resources.quadAcquired = true;
    XrSwapchainImageWaitInfo panelWait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; panelWait.timeout = XR_INFINITE_DURATION;
    XR_CHECK(xrWaitSwapchainImage(resources.quadSwapchain,&panelWait));
    id<MTLCommandBuffer> panelCommands = [queue commandBuffer];
    MTLRenderPassDescriptor* panelPass = [MTLRenderPassDescriptor renderPassDescriptor];
    panelPass.colorAttachments[0].texture = (__bridge id<MTLTexture>)quadImages[quadImageIndex].texture;
    panelPass.colorAttachments[0].loadAction = MTLLoadActionClear;
    panelPass.colorAttachments[0].storeAction = MTLStoreActionStore;
    id<MTLRenderCommandEncoder> panelEncoder = [panelCommands renderCommandEncoderWithDescriptor:panelPass];
    if (!panelCommands || !panelEncoder) return;
    [panelEncoder setRenderPipelineState:panelPipeline];
    [panelEncoder drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [panelEncoder endEncoding];
    [panelCommands commit];
    XrSwapchainImageReleaseInfo panelRelease{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    XR_CHECK(xrReleaseSwapchainImage(resources.quadSwapchain,&panelRelease));
    resources.quadAcquired = false;
    XrCompositionLayerQuad worldPanel{XR_TYPE_COMPOSITION_LAYER_QUAD};
    worldPanel.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT |
                           XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
    worldPanel.space = space; worldPanel.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    worldPanel.pose = {{0,0,0,1},{-.6f,.45f,-1.5f}}; worldPanel.size = {.8f,.4f};
    worldPanel.subImage = {resources.quadSwapchain,{{0,0},{512,256}},0};
    auto headPanel = worldPanel;
    headPanel.space = resources.view;
    headPanel.pose.position = {.32f,-.28f,-.85f}; headPanel.size = {.35f,.175f};
    std::fprintf(stderr, "VisionXR test: initialized; entering frame loop\n");
    bool wasTracked = false;

    // A bounded example so it can be stopped without platform-specific input.
    for(int frame=0;frame<3600;frame++) {
        @autoreleasepool {
            XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO};
            XrFrameState state{XR_TYPE_FRAME_STATE};
            XrResult waitResult = xrWaitFrame(session,&wi,&state);
            if (XR_FAILED(waitResult)) {
                std::fprintf(stderr, "VisionXR test: xrWaitFrame failed: %d\n", (int)waitResult);
                break;
            }
            XrFrameBeginInfo fbi{XR_TYPE_FRAME_BEGIN_INFO};
            XrResult beginResult = xrBeginFrame(session,&fbi);
            if (XR_FAILED(beginResult)) {
                std::fprintf(stderr, "VisionXR test: xrBeginFrame failed: %d\n", (int)beginResult);
                break;
            }
            resources.frameActive = true;
            resources.displayTime = state.predictedDisplayTime;
            XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
            end.displayTime = state.predictedDisplayTime;
            end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
            XrViewLocateInfo li{XR_TYPE_VIEW_LOCATE_INFO};
            li.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
            li.displayTime = state.predictedDisplayTime; li.space = space;
            XrViewState vs{XR_TYPE_VIEW_STATE};
            XrView views[2]={{XR_TYPE_VIEW},{XR_TYPE_VIEW}};
            XR_CHECK(xrLocateViews(session,&li,&vs,2,&count,views));
            XrSpaceLocation head{XR_TYPE_SPACE_LOCATION};
            XR_CHECK(xrLocateSpace(resources.view, space, state.predictedDisplayTime, &head));
            const bool tracked = count == 2 && (vs.viewStateFlags & validViews) == validViews &&
                                 (head.locationFlags & validHead) == validHead;
            if (frame == 0 || tracked != wasTracked)
                std::fprintf(stderr, "VisionXR test: headset pose %s\n", tracked ? "available" : "unavailable");
            if (tracked && (!wasTracked || frame % 90 == 0)) {
                auto p = head.pose.position; auto q = head.pose.orientation;
                std::fprintf(stderr, "VisionXR head LOCAL: position=(%.3f, %.3f, %.3f) m quaternion=(%.3f, %.3f, %.3f, %.3f)\n",
                             p.x,p.y,p.z,q.x,q.y,q.z,q.w);
            }
            wasTracked = tracked;
            if (!tracked || !state.shouldRender) {
                XrResult result = xrEndFrame(session, &end); // Zero layers while tracking is unavailable.
                resources.frameActive = false;
                if (XR_FAILED(result)) {
                    std::fprintf(stderr, "VisionXR test: xrEndFrame failed: %d\n", (int)result);
                    break;
                }
                continue;
            }
            uint32_t idx=0;
            XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
            XR_CHECK(xrAcquireSwapchainImage(sc,&acquire,&idx));
            resources.acquired = true;
            XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
            wait.timeout=XR_INFINITE_DURATION;
            XR_CHECK(xrWaitSwapchainImage(sc,&wait));

            id<MTLTexture> tex=(__bridge id<MTLTexture>)images[idx].texture;
            id<MTLCommandBuffer> cmd=[queue commandBuffer];
            if (!cmd || !scene.render(cmd, tex, views)) {
                std::fprintf(stderr, "VisionXR test: failed to encode tracked scene\n");
                return;
            }
            [cmd commit];
            XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
            XR_CHECK(xrReleaseSwapchainImage(sc,&release));
            resources.acquired = false;
            XrCompositionLayerProjectionView pv[2]={{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},
                                                   {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
            for(unsigned eye=0;eye<2;eye++) {
                pv[eye].pose=views[eye].pose;
                pv[eye].fov=views[eye].fov;
                pv[eye].subImage.swapchain=sc;
                pv[eye].subImage.imageArrayIndex=eye;
                pv[eye].subImage.imageRect.extent={(int32_t)width,(int32_t)height};
            }
            XrCompositionLayerProjection layer{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
            layer.space=space;layer.viewCount=2;layer.views=pv;
            const XrCompositionLayerBaseHeader* layers[] = {
                reinterpret_cast<const XrCompositionLayerBaseHeader*>(&layer),
                reinterpret_cast<const XrCompositionLayerBaseHeader*>(&worldPanel),
                reinterpret_cast<const XrCompositionLayerBaseHeader*>(&headPanel)};
            end.layerCount=3;end.layers=layers;
            XrResult result = xrEndFrame(session, &end);
            resources.frameActive = false;
            if (XR_FAILED(result)) {
                std::fprintf(stderr, "VisionXR test: xrEndFrame failed: %d\n", (int)result);
                break;
            }
        } // autoreleasepool
    }
    std::fprintf(stderr, "VisionXR test: frame loop finished\n");
    // ExampleResources releases spaces, swapchain and session on all exits.
}
