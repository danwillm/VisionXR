// Optional smoke-test renderer. Add to your visionOS Xcode App target.
// It displays two different clear colours via standard OpenXR calls.
#import <Metal/Metal.h>
#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <visionxr/host.h>
#include <cstdio>
#include <vector>

#define XR_CHECK(e) do { XrResult result=(e); if (XR_FAILED(result)) { \
    std::fprintf(stderr, "VisionXR example: %s failed: %d\n",#e,(int)result); return; } } while(0)

extern "C" void xrvision_run_example() {
    const char* extensions[]={XR_KHR_METAL_ENABLE_EXTENSION_NAME};
    XrInstanceCreateInfo ici{XR_TYPE_INSTANCE_CREATE_INFO};
    std::snprintf(ici.applicationInfo.applicationName, XR_MAX_APPLICATION_NAME_SIZE, "VisionXR Test");
    ici.applicationInfo.apiVersion=XR_CURRENT_API_VERSION;
    ici.enabledExtensionCount=1;
    ici.enabledExtensionNames=extensions;
    XrInstance instance{};
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
    XrSession session{};
    XR_CHECK(xrCreateSession(instance,&sci,&session));
    XrSessionBeginInfo bi{XR_TYPE_SESSION_BEGIN_INFO};
    bi.primaryViewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    XR_CHECK(xrBeginSession(session,&bi));

    XrViewConfigurationView configs[2]={{XR_TYPE_VIEW_CONFIGURATION_VIEW}, {XR_TYPE_VIEW_CONFIGURATION_VIEW}};
    uint32_t count=0;
    XR_CHECK(xrEnumerateViewConfigurationViews(instance,system,XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                                               2,&count,configs));
    const uint32_t width=configs[0].recommendedImageRectWidth;
    const uint32_t height=configs[0].recommendedImageRectHeight;
    XrSwapchainCreateInfo ci{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    ci.usageFlags=XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT | XR_SWAPCHAIN_USAGE_TRANSFER_SRC_BIT;
    ci.format=MTLPixelFormatBGRA8Unorm_sRGB; ci.sampleCount=1;
    ci.width=width;ci.height=height;ci.faceCount=1;ci.arraySize=2;ci.mipCount=1;
    XrSwapchain sc{};
    XR_CHECK(xrCreateSwapchain(session,&ci,&sc));
    uint32_t imageCount=0;
    XR_CHECK(xrEnumerateSwapchainImages(sc,0,&imageCount,nullptr));
    std::vector<XrSwapchainImageMetalKHR> images(imageCount);
    for(auto& image:images) image.type=XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR;
    XR_CHECK(xrEnumerateSwapchainImages(sc,imageCount,&imageCount,
                                       (XrSwapchainImageBaseHeader*)images.data()));
    XrReferenceSpaceCreateInfo rci{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    rci.referenceSpaceType=XR_REFERENCE_SPACE_TYPE_VIEW;
    rci.poseInReferenceSpace.orientation.w=1;
    XrSpace space{};
    XR_CHECK(xrCreateReferenceSpace(session,&rci,&space));

    // A bounded example so it can be stopped without platform-specific input.
    for(int frame=0;frame<600;frame++) {
        XrFrameWaitInfo wi{XR_TYPE_FRAME_WAIT_INFO};
        XrFrameState state{XR_TYPE_FRAME_STATE};
        if(XR_FAILED(xrWaitFrame(session,&wi,&state))) break;
        XrFrameBeginInfo fbi{XR_TYPE_FRAME_BEGIN_INFO};
        if(XR_FAILED(xrBeginFrame(session,&fbi))) break;
        uint32_t idx=0;
        XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
        XR_CHECK(xrAcquireSwapchainImage(sc,&acquire,&idx));
        XrSwapchainImageWaitInfo wait{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
        wait.timeout=XR_INFINITE_DURATION;
        XR_CHECK(xrWaitSwapchainImage(sc,&wait));

        id<MTLTexture> tex=(__bridge id<MTLTexture>)images[idx].texture;
        id<MTLCommandBuffer> cmd=[queue commandBuffer];
        for(unsigned eye=0;eye<2;eye++) {
            MTLRenderPassDescriptor* pass=[MTLRenderPassDescriptor renderPassDescriptor];
            pass.colorAttachments[0].texture=tex;
            pass.colorAttachments[0].slice=eye;
            pass.colorAttachments[0].loadAction=MTLLoadActionClear;
            pass.colorAttachments[0].storeAction=MTLStoreActionStore;
            pass.colorAttachments[0].clearColor=eye ? MTLClearColorMake(0.1,0.2,0.8,1) : MTLClearColorMake(0.8,0.2,0.1,1);
            id<MTLRenderCommandEncoder> encoder=[cmd renderCommandEncoderWithDescriptor:pass];
            [encoder endEncoding];
        }
        [cmd commit];
        XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        XR_CHECK(xrReleaseSwapchainImage(sc,&release));
        XrViewLocateInfo li{XR_TYPE_VIEW_LOCATE_INFO};
        li.viewConfigurationType=XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
        li.displayTime=state.predictedDisplayTime;li.space=space;
        XrViewState vs{XR_TYPE_VIEW_STATE};
        XrView views[2]={{XR_TYPE_VIEW},{XR_TYPE_VIEW}};
        XR_CHECK(xrLocateViews(session,&li,&vs,2,&count,views));
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
        const XrCompositionLayerBaseHeader* base=(const XrCompositionLayerBaseHeader*)&layer;
        XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
        end.displayTime=state.predictedDisplayTime;
        end.environmentBlendMode=XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
        end.layerCount=1;end.layers=&base;
        if(XR_FAILED(xrEndFrame(session,&end))) break;
    }
    XR_CHECK(xrDestroySpace(space));
    XR_CHECK(xrDestroySwapchain(sc));
    XR_CHECK(xrEndSession(session));
    XR_CHECK(xrDestroySession(session));
    XR_CHECK(xrDestroyInstance(instance));
}
