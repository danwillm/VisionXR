#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include "backend.hpp"
#include "pose.hpp"
#include <cstdio>
#include <cstdlib>

#define CHECK(x) do { if (!(x)) { std::fprintf(stderr, "Failed at line %d: %s\n", __LINE__, #x); std::abort(); } } while (0)

namespace backend {
    HeadLocation prediction{
        pose::identity(), XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
                          XR_SPACE_LOCATION_POSITION_VALID_BIT | XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
                          XR_SPACE_LOCATION_POSITION_TRACKED_BIT
    };
    XrTime queriedTime = 0;

    void attach(void *) {
    }

    void detach() {
    }

    bool ready() { return true; }
    void *device() { return reinterpret_cast<void *>(1); }
    bool configureQueue(void *) { return true; }
    uint32_t viewCount() { return 2; }
    XrTime now() { return 100; }

    HeadLocation locateHead(XrTime time) {
        queriedTime = time;
        return prediction;
    }

    XrResult createImage(uint32_t, uint32_t, uint32_t, int64_t, void** out) {
        *out = new int(0); return XR_SUCCESS;
    }

    void destroyImage(void* image) { delete static_cast<int*>(image); }

    XrResult waitFrame(Frame &f) {
        f.displayTimeNs = 100;
        return XR_SUCCESS;
    }

    XrResult beginFrame(Frame &f, std::vector<View> &views) {
        f.head = prediction;
        views = {
            {{{0, 0, 0, 1}, {-0.03f, 0, 0}}, {}, true},
            {{{0, 0, 0, 1}, {0.03f, 0, 0}}, {}, true}
        };
        return XR_SUCCESS;
    }

    std::vector<Layer> submittedLayers;
    unsigned submissions = 0;
    XrResult endFrame(Frame&, const std::vector<Layer>& layers) {
        submittedLayers = layers; ++submissions; return XR_SUCCESS;
    }
}

static void near(float a, float b) { CHECK(std::abs(a-b) < 0.0001f); }

static void same(XrPosef a, XrPosef b) {
    near(a.position.x, b.position.x);
    near(a.position.y, b.position.y);
    near(a.position.z, b.position.z);
    near(a.orientation.x, b.orientation.x);
    near(a.orientation.y, b.orientation.y);
    near(a.orientation.z, b.orientation.z);
    near(a.orientation.w, b.orientation.w);
}

int main() {
    const char *ext = XR_KHR_METAL_ENABLE_EXTENSION_NAME;
    XrInstanceCreateInfo ci{XR_TYPE_INSTANCE_CREATE_INFO};
    ci.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;
    ci.enabledExtensionCount = 1;
    ci.enabledExtensionNames = &ext;
    XrInstance instance;
    CHECK(xrCreateInstance(&ci, &instance) == XR_SUCCESS);

    XrGraphicsRequirementsMetalKHR requirements{XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR};
    CHECK(xrGetMetalGraphicsRequirementsKHR(instance, 1, &requirements) == XR_SUCCESS);
    XrGraphicsBindingMetalKHR binding{XR_TYPE_GRAPHICS_BINDING_METAL_KHR};
    XrSessionCreateInfo sci{XR_TYPE_SESSION_CREATE_INFO, &binding};
    sci.systemId = 1;
    XrSession session;

    CHECK(xrCreateSession(instance, &sci, &session) == XR_SUCCESS);
    XrSessionBeginInfo begin{XR_TYPE_SESSION_BEGIN_INFO};
    begin.primaryViewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;

    CHECK(xrBeginSession(session, &begin) == XR_SUCCESS);
    auto space = [&](XrReferenceSpaceType type, XrPosef offset) {
        XrReferenceSpaceCreateInfo info{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
        info.referenceSpaceType = type;
        info.poseInReferenceSpace = offset;
        XrSpace result;
        CHECK(xrCreateReferenceSpace(session, &info, &result) == XR_SUCCESS);
        return result;
    };
    XrSpace local = space(XR_REFERENCE_SPACE_TYPE_LOCAL, pose::identity());
    XrSpace view = space(XR_REFERENCE_SPACE_TYPE_VIEW, pose::identity());
    XrPosef offset{{0, 0.70710678f, 0, 0.70710678f}, {1, 2, 3}};
    XrSpace localOffset = space(XR_REFERENCE_SPACE_TYPE_LOCAL, offset);
    XrSpace viewOffset = space(XR_REFERENCE_SPACE_TYPE_VIEW, offset);
    XrReferenceSpaceCreateInfo invalid{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    invalid.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    XrSpace unused;
    CHECK(xrCreateReferenceSpace(session, &invalid, &unused) == XR_ERROR_POSE_INVALID);
    XrSpaceVelocity velocity{XR_TYPE_SPACE_VELOCITY};
    velocity.velocityFlags = XR_SPACE_VELOCITY_LINEAR_VALID_BIT;
    XrSpaceLocation loc{XR_TYPE_SPACE_LOCATION, &velocity};
    CHECK(xrLocateSpace(view, local, 0, &loc) == XR_ERROR_TIME_INVALID);
    // Initial LOCAL has head height and yaw, but preserves pitch/roll relative to gravity.
    backend::prediction.worldFromHead = {{0, 0.70710678f, 0, 0.70710678f}, {4, 1.6f, 6}};
    CHECK(xrLocateSpace(view, local, 50, &loc) == XR_SUCCESS);
    same(loc.pose, pose::identity());
    CHECK(velocity.velocityFlags == 0);
    backend::prediction.worldFromHead.position.z -= 2;
    CHECK(xrLocateSpace(view, local, 60, &loc) == XR_SUCCESS);
    CHECK(backend::queriedTime == 60);
    near(loc.pose.position.x, 2);
    near(loc.pose.position.y, 0);
    XrPosef localFromHead = loc.pose;
    CHECK(xrLocateSpace(local, view, 60, &loc) == XR_SUCCESS);
    same(loc.pose, pose::inverse(localFromHead));
    CHECK(xrLocateSpace(viewOffset, localOffset, 60, &loc) == XR_SUCCESS);
    same(loc.pose, pose::compose(pose::inverse(offset), pose::compose(localFromHead, offset)));
    CHECK(xrLocateSpace(localOffset, local, 60, &loc) == XR_SUCCESS);
    same(loc.pose, offset);

    XrFrameWaitInfo wait{XR_TYPE_FRAME_WAIT_INFO};
    XrFrameState frame{XR_TYPE_FRAME_STATE};
    XrFrameBeginInfo frameBegin{XR_TYPE_FRAME_BEGIN_INFO};
    CHECK(xrWaitFrame(session, &wait, &frame) == XR_SUCCESS);
    CHECK(xrBeginFrame(session, &frameBegin) == XR_SUCCESS);
    XrViewLocateInfo locate{XR_TYPE_VIEW_LOCATE_INFO};
    locate.viewConfigurationType = XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
    locate.space = local;
    locate.displayTime = frame.predictedDisplayTime;
    XrViewState state{XR_TYPE_VIEW_STATE};
    uint32_t count;
    XrView eyes[2]{{XR_TYPE_VIEW}, {XR_TYPE_VIEW}};
    // Changing the provider after BeginFrame must not change this frame's render pose.
    backend::prediction.worldFromHead.position.x += 10;
    CHECK(xrLocateViews(session, &locate, &state, 2, &count, eyes) == XR_SUCCESS);
    CHECK(backend::queriedTime == 60);
    near(eyes[0].pose.position.x, 1.97f);
    near(eyes[1].pose.position.x, 2.03f);
    CHECK(state.viewStateFlags & XR_VIEW_STATE_POSITION_TRACKED_BIT);
    locate.space = viewOffset;
    CHECK(xrLocateViews(session, &locate, &state, 2, &count, eyes) == XR_SUCCESS);
    same(eyes[0].pose, pose::compose(pose::inverse(offset), {{0, 0, 0, 1}, {-0.03f, 0, 0}}));
    // Query a different time with a rotated head to verify eye offsets rotate with it.
    locate.space = local;
    locate.displayTime = 120;
    backend::prediction.worldFromHead.orientation = {0, 1, 0, 0};
    CHECK(xrLocateViews(session, &locate, &state, 2, &count, eyes) == XR_SUCCESS);
    CHECK(xrLocateSpace(view, local, 120, &loc) == XR_SUCCESS);
    same(eyes[0].pose, pose::compose(loc.pose, {{0, 0, 0, 1}, {-0.03f, 0, 0}}));
    backend::prediction.flags = 0;
    CHECK(xrLocateSpace(view, local, 120, &loc) == XR_SUCCESS);
    CHECK(loc.locationFlags == 0);
    CHECK(xrLocateViews(session, &locate, &state, 2, &count, eyes) == XR_SUCCESS);
    CHECK(state.viewStateFlags == 0);
    CHECK(xrLocateSpace(viewOffset, view, 120, &loc) == XR_SUCCESS);
    same(loc.pose, offset);
    backend::prediction.flags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    CHECK(xrLocateSpace(view, local, 130, &loc) == XR_SUCCESS);
    CHECK(loc.locationFlags == backend::prediction.flags);
    near(loc.pose.position.x, 2);
    near(loc.pose.position.z, 10); // Original LOCAL origin survives recovery.
    XrSession other;
    CHECK(xrCreateSession(instance, &sci, &other) == XR_SUCCESS);
    XrReferenceSpaceCreateInfo otherInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    otherInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    otherInfo.poseInReferenceSpace = pose::identity();
    XrSpace otherSpace;
    CHECK(xrCreateReferenceSpace(other, &otherInfo, &otherSpace) == XR_SUCCESS);
    CHECK(xrLocateSpace(view, otherSpace, 130, &loc) == XR_ERROR_HANDLE_INVALID);
    CHECK(xrDestroySpace(otherSpace) == XR_SUCCESS);
    CHECK(xrDestroySession(other) == XR_SUCCESS);
    XrFrameEndInfo end{XR_TYPE_FRAME_END_INFO};
    end.displayTime = frame.predictedDisplayTime;
    end.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    CHECK(xrEndFrame(session, &end) == XR_SUCCESS);
    // Exercise actual xrEndFrame validation and translation with released images.
    XrSwapchainCreateInfo swapInfo{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    swapInfo.format = 81; swapInfo.width = 128; swapInfo.height = 64;
    swapInfo.arraySize = 2; swapInfo.faceCount = swapInfo.mipCount = swapInfo.sampleCount = 1;
    XrSwapchain swap;
    CHECK(xrCreateSwapchain(session, &swapInfo, &swap) == XR_SUCCESS);
    auto releaseImage = [&] {
        XrSwapchainImageAcquireInfo acquire{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO}; uint32_t index;
        CHECK(xrAcquireSwapchainImage(swap, &acquire, &index) == XR_SUCCESS);
        XrSwapchainImageWaitInfo waitImage{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO}; waitImage.timeout = XR_INFINITE_DURATION;
        CHECK(xrWaitSwapchainImage(swap, &waitImage) == XR_SUCCESS);
        XrSwapchainImageReleaseInfo release{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        CHECK(xrReleaseSwapchainImage(swap, &release) == XR_SUCCESS);
    };
    XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};
    quad.space = viewOffset; quad.eyeVisibility = XR_EYE_VISIBILITY_RIGHT;
    quad.pose = {{0,0,0,1},{0,0,-1}}; quad.size = {1,.5f};
    quad.subImage = {swap, {{16,8},{64,32}}, 1};
    quad.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT | XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
    XrCompositionLayerProjectionView projectionViews[2]{{XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW},
                                                       {XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW}};
    for (auto& v : projectionViews) { v.pose = pose::identity(); v.subImage = quad.subImage; }
    XrCompositionLayerProjection projection{XR_TYPE_COMPOSITION_LAYER_PROJECTION};
    projection.space = local; projection.viewCount = 2; projection.views = projectionViews;
    auto submit = [&](std::vector<const XrCompositionLayerBaseHeader*> layers, XrResult expected) {
        CHECK(xrWaitFrame(session, &wait, &frame) == XR_SUCCESS);
        CHECK(xrBeginFrame(session, &frameBegin) == XR_SUCCESS);
        end.layerCount = layers.size(); end.layers = layers.data();
        auto before = backend::submissions;
        CHECK(xrEndFrame(session, &end) == expected);
        CHECK(backend::submissions == before + 1); // Errors also close the compositor frame.
        if (XR_FAILED(expected)) CHECK(backend::submittedLayers.empty());
    };
    auto qbase = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&quad);
    auto pbase = reinterpret_cast<const XrCompositionLayerBaseHeader*>(&projection);
    submit({qbase}, XR_ERROR_LAYER_INVALID); // No released swapchain image yet.
    releaseImage();
    submit({pbase,qbase}, XR_SUCCESS);
    CHECK(backend::submittedLayers.size() == 2);
    CHECK(backend::submittedLayers[0].type == backend::Layer::Type::Projection);
    auto translated = backend::submittedLayers[1];
    CHECK(translated.type == backend::Layer::Type::Quad && translated.headRelative);
    CHECK(translated.eyeVisibility == XR_EYE_VISIBILITY_RIGHT && translated.flags == quad.layerFlags);
    CHECK(translated.images[0].srcSlice == 1 && translated.images[0].rect.offset.x == 16);
    same(translated.originFromQuad, pose::compose(offset,quad.pose));
    submit({qbase,pbase,qbase}, XR_SUCCESS);
    CHECK(backend::submittedLayers[0].type == backend::Layer::Type::Quad);
    CHECK(backend::submittedLayers[1].type == backend::Layer::Type::Projection);
    quad.space = localOffset;
    submit({qbase}, XR_SUCCESS);
    translated = backend::submittedLayers[0];
    CHECK(!translated.headRelative);
    same(translated.originFromQuad, pose::compose({{0,.70710678f,0,.70710678f},{4,1.6f,6}}, pose::compose(offset,quad.pose)));
    backend::prediction.flags = 0;
    submit({qbase}, XR_SUCCESS); CHECK(backend::submittedLayers.empty());
    quad.space = view;
    submit({qbase}, XR_SUCCESS); CHECK(backend::submittedLayers.size() == 1); // VIEW remains locatable.
    backend::prediction.flags = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT | XR_SPACE_LOCATION_POSITION_VALID_BIT;
    quad.size.width = 0; submit({qbase}, XR_ERROR_VALIDATION_FAILURE); quad.size.width = 1;
    quad.size.height = NAN; submit({qbase}, XR_ERROR_VALIDATION_FAILURE); quad.size.height = .5f;
    quad.pose.orientation.w = 0; submit({qbase}, XR_ERROR_POSE_INVALID); quad.pose.orientation.w = 1;
    quad.eyeVisibility = static_cast<XrEyeVisibility>(99); submit({qbase}, XR_ERROR_VALIDATION_FAILURE);
    quad.eyeVisibility = XR_EYE_VISIBILITY_LEFT;
    quad.subImage.imageArrayIndex = 2; submit({qbase}, XR_ERROR_LAYER_INVALID); quad.subImage.imageArrayIndex = 1;
    quad.subImage.imageRect.offset.x = -1; submit({qbase}, XR_ERROR_SWAPCHAIN_RECT_INVALID);
    quad.subImage.imageRect.offset.x = INT32_MAX; submit({qbase}, XR_ERROR_SWAPCHAIN_RECT_INVALID);
    quad.subImage.imageRect.offset.x = 16;
    quad.layerFlags = 0x80000000; submit({qbase}, XR_ERROR_VALIDATION_FAILURE); quad.layerFlags = 0;
    quad.space = XR_NULL_HANDLE; submit({qbase}, XR_ERROR_HANDLE_INVALID); quad.space = view;
    submit({nullptr}, XR_ERROR_LAYER_INVALID);
    submit(std::vector<const XrCompositionLayerBaseHeader*>(backend::maxLayers,qbase), XR_SUCCESS);
    CHECK(backend::submittedLayers.size() == backend::maxLayers);
    submit(std::vector<const XrCompositionLayerBaseHeader*>(backend::maxLayers+1,qbase), XR_ERROR_LAYER_LIMIT_EXCEEDED);
    XrSystemProperties properties{XR_TYPE_SYSTEM_PROPERTIES};
    CHECK(xrGetSystemProperties(instance,1,&properties) == XR_SUCCESS);
    CHECK(properties.graphicsProperties.maxLayerCount == backend::maxLayers);
    CHECK(xrDestroySwapchain(swap) == XR_SUCCESS);
    CHECK(xrEndSession(session) == XR_SUCCESS);
    for (auto sp: {local, view, localOffset, viewOffset})
        CHECK(xrDestroySpace(sp) == XR_SUCCESS);
    CHECK(xrDestroySession(session) == XR_SUCCESS);
    CHECK(xrDestroyInstance(instance) == XR_SUCCESS);
    std::puts("Tracking, reference spaces, quad/projection composition, ordering and invalid submissions: OK");
}
