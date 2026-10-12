#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <visionxr/host.h>
#include "backend.hpp"
#include "pose.hpp"
#include <algorithm>
#include <array>
#include <cstring>
#include <deque>
#include <memory>
#include <string>
#include <vector>

struct XrInstance_T {
    bool metal = false;
    bool requirementsRead = false;
    std::deque<XrEventDataSessionStateChanged> events;
};

struct XrSession_T {
    XrInstance instance{};
    bool running = false;
    bool waited = false;
    bool begun = false;
    XrSessionState state = XR_SESSION_STATE_IDLE;
    backend::Frame frame;
    std::vector<backend::View> views;
    std::vector<XrSwapchain> swapchains;
    XrPosef worldFromLocal = pose::identity();
    bool localInitialized = false;
};

struct XrSwapchain_T {
    XrSession session{};
    XrSwapchainCreateInfo info{};
    std::vector<void *> images;
    uint32_t cursor = 0;
    uint32_t acquired = UINT32_MAX;
    uint32_t submitted = UINT32_MAX;
    bool waited = false;
};

struct XrSpace_T {
    XrSession session{};
    XrReferenceSpaceType type{};
    XrPosef pose{};
};

namespace {
    constexpr XrSystemId SYSTEM_ID = 1;
    constexpr int64_t BGRA8_SRGB = 81;
    unsigned g_width = 3200, g_height = 3200;
    constexpr XrPosef identity() { return {{0.f, 0.f, 0.f, 1.f}, {0.f, 0.f, 0.f}}; }

    template<typename T>
    XrResult enumerate(const std::vector<T> &values, uint32_t cap,
                       uint32_t *count, T *out) {
        if (!count) return XR_ERROR_VALIDATION_FAILURE;
        *count = static_cast<uint32_t>(values.size());
        if (cap == 0) return XR_SUCCESS;
        if (!out) return XR_ERROR_VALIDATION_FAILURE;
        if (cap < values.size()) return XR_ERROR_SIZE_INSUFFICIENT;
        std::copy(values.begin(), values.end(), out);
        return XR_SUCCESS;
    }

    void changed(XrSession s, XrSessionState state) {
        s->state = state;
        XrEventDataSessionStateChanged e{};
        e.type = XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED;
        e.session = s;
        e.state = state;
        e.time = backend::now();
        s->instance->events.push_back(e);
    }

    constexpr XrSpaceLocationFlags validPose = XR_SPACE_LOCATION_ORIENTATION_VALID_BIT |
                                              XR_SPACE_LOCATION_POSITION_VALID_BIT;
    constexpr XrSpaceLocationFlags trackedPose = validPose | XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT |
                                                XR_SPACE_LOCATION_POSITION_TRACKED_BIT;

    backend::HeadLocation headInLocal(XrSession s, XrTime time) {
        auto head = s->begun && time == s->frame.displayTimeNs
                        ? s->frame.head : backend::locateHead(time);
        if ((head.flags & validPose) != validPose) return {};
        if (!s->localInitialized) {
            s->worldFromLocal = pose::localOrigin(head.worldFromHead);
            s->localInitialized = true;
        }
        head.worldFromHead = pose::compose(pose::inverse(s->worldFromLocal), head.worldFromHead);
        return head;
    }
    XrPosef localFromSpace(XrSpace space, XrPosef localFromHead) {
        return space->type == XR_REFERENCE_SPACE_TYPE_VIEW
                   ? pose::compose(localFromHead, space->pose) : space->pose;
    }

    XrResult validateSystem(XrInstance i, XrSystemId s) {
        if (!i) return XR_ERROR_HANDLE_INVALID;
        return s == SYSTEM_ID ? XR_SUCCESS : XR_ERROR_SYSTEM_INVALID;
    }
}

extern "C" void xrvision_set_recommended_view_size(unsigned w, unsigned h) {
    if (w && h) {
        g_width = w;
        g_height = h;
    }
}

extern "C" {
XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateApiLayerProperties(uint32_t cap, uint32_t *count, XrApiLayerProperties *out) {
    return enumerate(std::vector<XrApiLayerProperties>{}, cap, count, out);
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateInstanceExtensionProperties(const char *layer, uint32_t cap,
                                                                      uint32_t *count, XrExtensionProperties *out) {
    if (layer) return XR_ERROR_API_LAYER_NOT_PRESENT;
    XrExtensionProperties ext{};
    ext.type = XR_TYPE_EXTENSION_PROPERTIES;
    std::strncpy(ext.extensionName, XR_KHR_METAL_ENABLE_EXTENSION_NAME, XR_MAX_EXTENSION_NAME_SIZE - 1);
    ext.extensionVersion = XR_KHR_metal_enable_SPEC_VERSION;
    if (!count) return XR_ERROR_VALIDATION_FAILURE;
    *count = 1;
    if (cap == 0) return XR_SUCCESS;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    if (cap < 1) return XR_ERROR_SIZE_INSUFFICIENT;
    if (out[0].type != XR_TYPE_EXTENSION_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
    out[0] = ext;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateInstance(const XrInstanceCreateInfo *ci, XrInstance *out) {
    if (!ci || !out || ci->type != XR_TYPE_INSTANCE_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;

    if (ci->enabledApiLayerCount) return XR_ERROR_API_LAYER_NOT_PRESENT;

    if (XR_VERSION_MAJOR(ci->applicationInfo.apiVersion) > XR_VERSION_MAJOR(XR_CURRENT_API_VERSION)) {
        return XR_ERROR_API_VERSION_UNSUPPORTED;
    }

    bool metal = false;
    for (uint32_t i = 0; i < ci->enabledExtensionCount; i++) {
        if (!ci->enabledExtensionNames || !ci->enabledExtensionNames[i]) return XR_ERROR_VALIDATION_FAILURE;
        if (std::strcmp(ci->enabledExtensionNames[i],XR_KHR_METAL_ENABLE_EXTENSION_NAME) == 0) metal = true;
        else return XR_ERROR_EXTENSION_NOT_PRESENT;
    }
    *out = new XrInstance_T{metal, false, {}};
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroyInstance(XrInstance i) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    delete i;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProperties(XrInstance i, XrInstanceProperties *p) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    if (!p || p->type != XR_TYPE_INSTANCE_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
    p->runtimeVersion = XR_MAKE_VERSION(0, 1, 0);
    std::strncpy(p->runtimeName, "VisionXR Shim",XR_MAX_RUNTIME_NAME_SIZE - 1);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetSystem(XrInstance i, const XrSystemGetInfo *gi, XrSystemId *out) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    if (!gi || !out || gi->type != XR_TYPE_SYSTEM_GET_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (gi->formFactor != XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY) return XR_ERROR_FORM_FACTOR_UNSUPPORTED;
    if (!backend::ready()) return XR_ERROR_FORM_FACTOR_UNAVAILABLE;
    *out = SYSTEM_ID;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetSystemProperties(XrInstance i, XrSystemId sid, XrSystemProperties *p) {
    if (auto err = validateSystem(i, sid); err != XR_SUCCESS) return err;
    if (!p || p->type != XR_TYPE_SYSTEM_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
    p->systemId = sid;
    p->vendorId = 0;
    std::strncpy(p->systemName, "visionOS CompositorLayer",XR_MAX_SYSTEM_NAME_SIZE - 1);
    p->graphicsProperties.maxSwapchainImageWidth = 8192;
    p->graphicsProperties.maxSwapchainImageHeight = 8192;
    p->graphicsProperties.maxLayerCount = backend::maxLayers;
    p->trackingProperties.orientationTracking = XR_TRUE;
    p->trackingProperties.positionTracking = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateViewConfigurations(XrInstance i, XrSystemId sid,
                                                             uint32_t cap, uint32_t *count,
                                                             XrViewConfigurationType *out) {
    if (auto err = validateSystem(i, sid); err != XR_SUCCESS) return err;
    return enumerate(std::vector<XrViewConfigurationType>{XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO}, cap, count, out);
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetViewConfigurationProperties(XrInstance i, XrSystemId sid,
                                                                XrViewConfigurationType vc,
                                                                XrViewConfigurationProperties *out) {
    if (auto err = validateSystem(i, sid); err != XR_SUCCESS) return err;
    if (!out || out->type != XR_TYPE_VIEW_CONFIGURATION_PROPERTIES) return XR_ERROR_VALIDATION_FAILURE;
    if (vc != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    out->viewConfigurationType = vc;
    out->fovMutable = XR_FALSE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateViewConfigurationViews(XrInstance i, XrSystemId sid,
                                                                 XrViewConfigurationType vc, uint32_t cap,
                                                                 uint32_t *count, XrViewConfigurationView *out) {
    if (auto err = validateSystem(i, sid); err != XR_SUCCESS) return err;
    if (vc != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    if (!count) return XR_ERROR_VALIDATION_FAILURE;
    *count = 2;
    if (!cap) return XR_SUCCESS;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    if (cap < 2) return XR_ERROR_SIZE_INSUFFICIENT;
    for (int j = 0; j < 2; j++) {
        if (out[j].type != XR_TYPE_VIEW_CONFIGURATION_VIEW) return XR_ERROR_VALIDATION_FAILURE;
        out[j].recommendedImageRectWidth = g_width;
        out[j].maxImageRectWidth = 8192;
        out[j].recommendedImageRectHeight = g_height;
        out[j].maxImageRectHeight = 8192;
        out[j].recommendedSwapchainSampleCount = 1;
        out[j].maxSwapchainSampleCount = 1;
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateEnvironmentBlendModes(XrInstance i, XrSystemId sid,
                                                                XrViewConfigurationType vc, uint32_t cap,
                                                                uint32_t *count, XrEnvironmentBlendMode *out) {
    if (auto err = validateSystem(i, sid); err != XR_SUCCESS) return err;
    if (vc != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO) return XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    return enumerate(std::vector<XrEnvironmentBlendMode>{XR_ENVIRONMENT_BLEND_MODE_OPAQUE}, cap, count, out);
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetMetalGraphicsRequirementsKHR(XrInstance i, XrSystemId sid,
                                                                 XrGraphicsRequirementsMetalKHR *out) {
    if (auto err = validateSystem(i, sid); err != XR_SUCCESS) return err;
    if (!i->metal) return XR_ERROR_FUNCTION_UNSUPPORTED;
    if (!out || out->type != XR_TYPE_GRAPHICS_REQUIREMENTS_METAL_KHR) return XR_ERROR_VALIDATION_FAILURE;
    void *gpu = backend::device();
    if (!gpu) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    out->metalDevice = gpu;
    i->requirementsRead = true;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateSession(XrInstance i, const XrSessionCreateInfo *ci, XrSession *out) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    if (!ci || !out || ci->type != XR_TYPE_SESSION_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (ci->systemId != SYSTEM_ID) return XR_ERROR_SYSTEM_INVALID;
    if (!i->metal) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    if (!i->requirementsRead) return XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING;
    auto *b = static_cast<const XrBaseInStructure *>(ci->next);
    while (b && b->type != XR_TYPE_GRAPHICS_BINDING_METAL_KHR) b = b->next;
    if (!b) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    auto *metal = reinterpret_cast<const XrGraphicsBindingMetalKHR *>(b);
    if (!backend::configureQueue(metal->commandQueue)) return XR_ERROR_GRAPHICS_DEVICE_INVALID;
    auto *s = new XrSession_T{};
    s->instance = i;
    *out = s;
    changed(s, XR_SESSION_STATE_READY);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySession(XrSession s) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!s->swapchains.empty()) return XR_ERROR_CALL_ORDER_INVALID;
    delete s;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrPollEvent(XrInstance i, XrEventDataBuffer *out) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    if (!out || out->type != XR_TYPE_EVENT_DATA_BUFFER) return XR_ERROR_VALIDATION_FAILURE;
    if (i->events.empty()) return XR_EVENT_UNAVAILABLE;
    auto e = i->events.front();
    i->events.pop_front();
    std::memcpy(out, &e, sizeof(e));
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrBeginSession(XrSession s, const XrSessionBeginInfo *bi) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!bi || bi->type != XR_TYPE_SESSION_BEGIN_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (bi->primaryViewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)
        return
                XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    if (s->running) return XR_ERROR_SESSION_RUNNING;
    if (!backend::ready()) return XR_ERROR_SESSION_NOT_READY;
    s->localInitialized = false;
    s->running = true;
    changed(s, XR_SESSION_STATE_FOCUSED);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEndSession(XrSession s) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (s->waited || s->begun) return XR_ERROR_CALL_ORDER_INVALID;
    s->running = false;
    changed(s, XR_SESSION_STATE_IDLE);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrRequestExitSession(XrSession s) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    changed(s, XR_SESSION_STATE_STOPPING);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateReferenceSpaces(XrSession s, uint32_t cap,
                                                          uint32_t *count, XrReferenceSpaceType *out) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    return enumerate(std::vector<XrReferenceSpaceType>{XR_REFERENCE_SPACE_TYPE_VIEW, XR_REFERENCE_SPACE_TYPE_LOCAL},
                     cap, count, out);
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateReferenceSpace(XrSession s, const XrReferenceSpaceCreateInfo *ci, XrSpace *out) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!ci || !out || ci->type != XR_TYPE_REFERENCE_SPACE_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (ci->referenceSpaceType != XR_REFERENCE_SPACE_TYPE_VIEW && ci->referenceSpaceType !=
        XR_REFERENCE_SPACE_TYPE_LOCAL)
        return XR_ERROR_REFERENCE_SPACE_UNSUPPORTED;
    if (!pose::valid(ci->poseInReferenceSpace)) return XR_ERROR_POSE_INVALID;
    *out = new XrSpace_T{s, ci->referenceSpaceType, ci->poseInReferenceSpace};
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySpace(XrSpace space) {
    if (!space) return XR_ERROR_HANDLE_INVALID;
    delete space;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrLocateSpace(XrSpace space, XrSpace base, XrTime time, XrSpaceLocation *loc) {
    if (!space || !base || space->session != base->session) return XR_ERROR_HANDLE_INVALID;
    if (!loc || loc->type != XR_TYPE_SPACE_LOCATION) return XR_ERROR_VALIDATION_FAILURE;
    if (time <= 0) return XR_ERROR_TIME_INVALID;

    loc->locationFlags = 0;
    loc->pose = identity();

    // No velocity estimate is supplied. Clear a caller's reused velocity flags.
    for (auto* next = static_cast<XrBaseOutStructure*>(loc->next); next; next = next->next)
        if (next->type == XR_TYPE_SPACE_VELOCITY)
            reinterpret_cast<XrSpaceVelocity*>(next)->velocityFlags = 0;

    if (space->type == base->type) {
        loc->pose = pose::compose(pose::inverse(base->pose), space->pose);
        loc->locationFlags = trackedPose;
    } else {
        auto head = headInLocal(space->session, time);
        if ((head.flags & validPose) == validPose) {
            loc->pose = pose::compose(pose::inverse(localFromSpace(base, head.worldFromHead)),
                                     localFromSpace(space, head.worldFromHead));
            loc->locationFlags = head.flags;
        }
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrGetReferenceSpaceBoundsRect(XrSession s, XrReferenceSpaceType,
                                                             XrExtent2Df *out) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    *out = {0, 0};
    return XR_SPACE_BOUNDS_UNAVAILABLE;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateSwapchainFormats(XrSession s, uint32_t cap,
                                                           uint32_t *count, int64_t *out) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    return enumerate(std::vector<int64_t>{BGRA8_SRGB}, cap, count, out);
}

XRAPI_ATTR XrResult XRAPI_CALL xrCreateSwapchain(XrSession s, const XrSwapchainCreateInfo *ci, XrSwapchain *out) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!ci || !out || ci->type != XR_TYPE_SWAPCHAIN_CREATE_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (ci->format != BGRA8_SRGB) return XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED;
    if (ci->width == 0 || ci->height == 0 || ci->width > 8192 || ci->height > 8192 || ci->arraySize == 0 ||
        ci->faceCount != 1 || ci->mipCount != 1 || ci->sampleCount != 1 || ci->arraySize > 2)
        return XR_ERROR_VALIDATION_FAILURE;
    auto swap = std::make_unique<XrSwapchain_T>();
    swap->session = s;
    swap->info = *ci;
    for (int k = 0; k < 3; k++) {
        void *image = nullptr;
        auto err = backend::createImage(ci->width, ci->height, ci->arraySize, ci->format, &image);
        if (err != XR_SUCCESS) {
            for (auto *t: swap->images) backend::destroyImage(t);
            return err;
        }
        swap->images.push_back(image);
    }
    *out = swap.release();
    s->swapchains.push_back(*out);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrDestroySwapchain(XrSwapchain sc) {
    if (!sc) return XR_ERROR_HANDLE_INVALID;
    if (sc->acquired != UINT32_MAX) return XR_ERROR_CALL_ORDER_INVALID;
    auto &v = sc->session->swapchains;
    v.erase(std::remove(v.begin(), v.end(), sc), v.end());
    for (auto *img: sc->images) backend::destroyImage(img);
    delete sc;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEnumerateSwapchainImages(XrSwapchain sc, uint32_t cap,
                                                          uint32_t *count, XrSwapchainImageBaseHeader *out) {
    if (!sc) return XR_ERROR_HANDLE_INVALID;
    if (!count) return XR_ERROR_VALIDATION_FAILURE;
    *count = static_cast<uint32_t>(sc->images.size());
    if (!cap) return XR_SUCCESS;
    if (!out) return XR_ERROR_VALIDATION_FAILURE;
    if (cap < sc->images.size()) return XR_ERROR_SIZE_INSUFFICIENT;
    auto *images = reinterpret_cast<XrSwapchainImageMetalKHR *>(out);
    for (size_t j = 0; j < sc->images.size(); j++) {
        if (images[j].type != XR_TYPE_SWAPCHAIN_IMAGE_METAL_KHR) return XR_ERROR_VALIDATION_FAILURE;
        images[j].texture = sc->images[j];
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrAcquireSwapchainImage(XrSwapchain sc, const XrSwapchainImageAcquireInfo *ai,
                                                       uint32_t *idx) {
    if (!sc) return XR_ERROR_HANDLE_INVALID;
    if (!ai || ai->type != XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO || !idx) return XR_ERROR_VALIDATION_FAILURE;
    if (sc->acquired != UINT32_MAX) return XR_ERROR_CALL_ORDER_INVALID;
    sc->acquired = sc->cursor++ % static_cast<uint32_t>(sc->images.size());
    sc->waited = false;
    *idx = sc->acquired;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrWaitSwapchainImage(XrSwapchain sc, const XrSwapchainImageWaitInfo *wi) {
    if (!sc) return XR_ERROR_HANDLE_INVALID;
    if (!wi || wi->type != XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (sc->acquired == UINT32_MAX) return XR_ERROR_CALL_ORDER_INVALID;
    sc->waited = true;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrReleaseSwapchainImage(XrSwapchain sc, const XrSwapchainImageReleaseInfo *ri) {
    if (!sc) return XR_ERROR_HANDLE_INVALID;
    if (!ri || ri->type != XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (sc->acquired == UINT32_MAX || !sc->waited) return XR_ERROR_CALL_ORDER_INVALID;
    sc->submitted = sc->acquired;
    sc->acquired = UINT32_MAX;
    sc->waited = false;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrWaitFrame(XrSession s, const XrFrameWaitInfo *wi, XrFrameState *fs) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!wi || wi->type != XR_TYPE_FRAME_WAIT_INFO || !fs || fs->type != XR_TYPE_FRAME_STATE)
        return XR_ERROR_VALIDATION_FAILURE;
    if (!s->running) return XR_ERROR_SESSION_NOT_RUNNING;
    if (s->waited || s->begun) return XR_ERROR_CALL_ORDER_INVALID;
    auto err = backend::waitFrame(s->frame);
    if (err != XR_SUCCESS) return err;
    s->waited = true;
    fs->predictedDisplayTime = s->frame.displayTimeNs;
    fs->predictedDisplayPeriod = 11111111; // temporary; refresh rate query is a future task
    fs->shouldRender = XR_TRUE;
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrBeginFrame(XrSession s, const XrFrameBeginInfo *bi) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!bi || bi->type != XR_TYPE_FRAME_BEGIN_INFO) return XR_ERROR_VALIDATION_FAILURE;
    if (!s->waited || s->begun) return XR_ERROR_CALL_ORDER_INVALID;
    auto err = backend::beginFrame(s->frame, s->views);
    if (err != XR_SUCCESS) {
        s->waited = false;
        s->frame = {};
        return err;
    }
    s->begun = true;
    headInLocal(s, s->frame.displayTimeNs);
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrLocateViews(XrSession s, const XrViewLocateInfo *li,
                                             XrViewState *state, uint32_t cap, uint32_t *count, XrView *views) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!li || li->type != XR_TYPE_VIEW_LOCATE_INFO || !state || state->type != XR_TYPE_VIEW_STATE || !count)
        return XR_ERROR_VALIDATION_FAILURE;
    if (li->viewConfigurationType != XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO)
        return
                XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED;
    if (!li->space || li->space->session != s) return XR_ERROR_HANDLE_INVALID;
    if (li->displayTime <= 0) return XR_ERROR_TIME_INVALID;
    state->viewStateFlags = 0;
    *count = 2;
    if (!cap) return XR_SUCCESS;
    if (cap < 2) return XR_ERROR_SIZE_INSUFFICIENT;
    if (!views) return XR_ERROR_VALIDATION_FAILURE;
    XrPosef baseFromHead = pose::inverse(li->space->pose);
    XrSpaceLocationFlags flags = trackedPose;
    if (li->space->type == XR_REFERENCE_SPACE_TYPE_LOCAL) {
        auto head = headInLocal(s, li->displayTime);
        flags = head.flags;
        baseFromHead = pose::compose(baseFromHead, head.worldFromHead);
    }
    bool available = s->views.size() >= 2 && s->views[0].available && s->views[1].available;
    if (available) {
        if (flags & XR_SPACE_LOCATION_ORIENTATION_VALID_BIT) state->viewStateFlags |= XR_VIEW_STATE_ORIENTATION_VALID_BIT;
        if (flags & XR_SPACE_LOCATION_POSITION_VALID_BIT) state->viewStateFlags |= XR_VIEW_STATE_POSITION_VALID_BIT;
        if (flags & XR_SPACE_LOCATION_ORIENTATION_TRACKED_BIT) state->viewStateFlags |= XR_VIEW_STATE_ORIENTATION_TRACKED_BIT;
        if (flags & XR_SPACE_LOCATION_POSITION_TRACKED_BIT) state->viewStateFlags |= XR_VIEW_STATE_POSITION_TRACKED_BIT;
    }
    for (int i = 0; i < 2; i++) {
        if (views[i].type != XR_TYPE_VIEW) return XR_ERROR_VALIDATION_FAILURE;
        views[i].pose = available && (flags & validPose) == validPose
                            ? pose::compose(baseFromHead, s->views[i].eyeFromHead) : identity();
        views[i].fov = s->views.size() > i ? s->views[i].fov : XrFovf{};
    }
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrEndFrame(XrSession s, const XrFrameEndInfo *ei) {
    if (!s) return XR_ERROR_HANDLE_INVALID;
    if (!s->begun) return XR_ERROR_CALL_ORDER_INVALID;

    auto finish = [&](XrResult validation, const std::vector<backend::Layer>& layers) {
        const XrResult backendResult = backend::endFrame(s->frame, layers);
        s->frame = {};
        s->begun = false;
        s->waited = false;
        s->views.clear();
        return validation != XR_SUCCESS ? validation : backendResult;
    };
    const std::vector<backend::Layer> empty;
    if (!ei || ei->type != XR_TYPE_FRAME_END_INFO)
        return finish(XR_ERROR_VALIDATION_FAILURE, empty);
    if (ei->displayTime <= 0) return finish(XR_ERROR_TIME_INVALID, empty);
    if (ei->environmentBlendMode != XR_ENVIRONMENT_BLEND_MODE_OPAQUE)
        return finish(XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED, empty);
    if (ei->layerCount && !ei->layers)
        return finish(XR_ERROR_VALIDATION_FAILURE, empty);
    if (ei->layerCount > backend::maxLayers)
        return finish(XR_ERROR_LAYER_LIMIT_EXCEEDED, empty);

    auto image = [&](const XrSwapchainSubImage& sub, backend::Copy& out) -> XrResult {
        auto* sc = sub.swapchain;
        if (!sc || sc->session != s || sc->submitted == UINT32_MAX ||
            sub.imageArrayIndex >= sc->info.arraySize) return XR_ERROR_LAYER_INVALID;
        const auto& r = sub.imageRect;
        if (r.offset.x < 0 || r.offset.y < 0 || r.extent.width <= 0 || r.extent.height <= 0 ||
            int64_t(r.offset.x) + r.extent.width > sc->info.width ||
            int64_t(r.offset.y) + r.extent.height > sc->info.height)
            return XR_ERROR_SWAPCHAIN_RECT_INVALID;
        out = {sc->images[sc->submitted], sub.imageArrayIndex, r};
        return XR_SUCCESS;
    };
    constexpr XrCompositionLayerFlags supportedFlags = XR_COMPOSITION_LAYER_CORRECT_CHROMATIC_ABERRATION_BIT |
        XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT | XR_COMPOSITION_LAYER_UNPREMULTIPLIED_ALPHA_BIT;
    std::vector<backend::Layer> layers;
    for (uint32_t index = 0; index < ei->layerCount; ++index) {
        const auto* base = ei->layers[index];
        if (!base) return finish(XR_ERROR_LAYER_INVALID, empty);
        if (!base->space || base->space->session != s) return finish(XR_ERROR_HANDLE_INVALID, empty);
        if (base->layerFlags & ~supportedFlags) return finish(XR_ERROR_VALIDATION_FAILURE, empty);
        backend::Layer translated;
        translated.flags = base->layerFlags;
        if (base->type == XR_TYPE_COMPOSITION_LAYER_PROJECTION) {
            const auto* layer = reinterpret_cast<const XrCompositionLayerProjection*>(base);
            if (layer->viewCount != 2 || !layer->views) return finish(XR_ERROR_LAYER_INVALID, empty);
            for (uint32_t eye = 0; eye < 2; ++eye) {
                const auto& v = layer->views[eye];
                if (v.type != XR_TYPE_COMPOSITION_LAYER_PROJECTION_VIEW) return finish(XR_ERROR_LAYER_INVALID, empty);
                if (!pose::valid(v.pose)) return finish(XR_ERROR_POSE_INVALID, empty);
                if (auto err = image(v.subImage, translated.images[eye]); err != XR_SUCCESS)
                    return finish(err, empty);
            }
        } else if (base->type == XR_TYPE_COMPOSITION_LAYER_QUAD) {
            const auto* quad = reinterpret_cast<const XrCompositionLayerQuad*>(base);
            if (!pose::valid(quad->pose)) return finish(XR_ERROR_POSE_INVALID, empty);
            if (!std::isfinite(quad->size.width) || !std::isfinite(quad->size.height) ||
                quad->size.width <= 0 || quad->size.height <= 0)
                return finish(XR_ERROR_VALIDATION_FAILURE, empty);
            if (quad->eyeVisibility != XR_EYE_VISIBILITY_BOTH && quad->eyeVisibility != XR_EYE_VISIBILITY_LEFT &&
                quad->eyeVisibility != XR_EYE_VISIBILITY_RIGHT) return finish(XR_ERROR_VALIDATION_FAILURE, empty);
            if (auto err = image(quad->subImage, translated.images[0]); err != XR_SUCCESS)
                return finish(err, empty);
            translated.type = backend::Layer::Type::Quad;
            translated.eyeVisibility = quad->eyeVisibility;
            translated.size = quad->size;
            translated.headRelative = base->space->type == XR_REFERENCE_SPACE_TYPE_VIEW;
            auto originFromSpace = translated.headRelative ? base->space->pose
                : pose::compose(s->worldFromLocal, base->space->pose);
            translated.originFromQuad = pose::compose(originFromSpace, quad->pose);
        } else {
            return finish(XR_ERROR_LAYER_INVALID, empty);
        }
        // Omit any layer whose LOCAL space cannot currently be located.
        if (base->space->type == XR_REFERENCE_SPACE_TYPE_LOCAL &&
            (!s->localInitialized || (s->frame.head.flags & validPose) != validPose)) continue;
        layers.push_back(translated);
    }
    return finish(XR_SUCCESS, layers);
}

XRAPI_ATTR XrResult XRAPI_CALL xrResultToString(XrInstance i, XrResult value, char buffer[XR_MAX_RESULT_STRING_SIZE]) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    if (!buffer) return XR_ERROR_VALIDATION_FAILURE;
    const char *text = "XR_UNKNOWN_RESULT";
    switch (value) {
        case XR_SUCCESS: text = "XR_SUCCESS";
            break;
        case XR_EVENT_UNAVAILABLE: text = "XR_EVENT_UNAVAILABLE";
            break;
        case XR_ERROR_FUNCTION_UNSUPPORTED: text = "XR_ERROR_FUNCTION_UNSUPPORTED";
            break;
        case XR_ERROR_RUNTIME_FAILURE: text = "XR_ERROR_RUNTIME_FAILURE";
            break;
        default: break;
    }
    std::strncpy(buffer, text,XR_MAX_RESULT_STRING_SIZE - 1);
    buffer[XR_MAX_RESULT_STRING_SIZE - 1] = '\0';
    return XR_SUCCESS;
}

XRAPI_ATTR XrResult XRAPI_CALL xrStructureTypeToString(XrInstance i, XrStructureType,
                                                       char buffer[XR_MAX_STRUCTURE_NAME_SIZE]) {
    if (!i) return XR_ERROR_HANDLE_INVALID;
    if (!buffer) return XR_ERROR_VALIDATION_FAILURE;
    std::strncpy(buffer, "XR_UNKNOWN_STRUCTURE_TYPE",XR_MAX_STRUCTURE_NAME_SIZE - 1);
    buffer[XR_MAX_STRUCTURE_NAME_SIZE - 1] = '\0';
    return XR_SUCCESS;
}

// The dispatch table is intentionally explicit. Unimplemented XR commands are
// reported as unsupported, not silently replaced with fake success.
XRAPI_ATTR XrResult XRAPI_CALL xrGetInstanceProcAddr(XrInstance inst, const char *name,
                                                     PFN_xrVoidFunction *out) {
    if (!name || !out) return XR_ERROR_VALIDATION_FAILURE;
    *out = nullptr;
#define DISPATCH(fn) if(std::strcmp(name,#fn)==0) { *out=(PFN_xrVoidFunction)&fn; return XR_SUCCESS; }
    DISPATCH(xrGetInstanceProcAddr)
    DISPATCH(xrEnumerateApiLayerProperties)
    DISPATCH(xrEnumerateInstanceExtensionProperties)
    DISPATCH(xrCreateInstance)
    if (!inst) return XR_ERROR_FUNCTION_UNSUPPORTED;
    DISPATCH(xrDestroyInstance)
    DISPATCH(xrGetInstanceProperties)
    DISPATCH(xrGetSystem)
    DISPATCH(xrGetSystemProperties)
    DISPATCH(xrEnumerateViewConfigurations)
    DISPATCH(xrGetViewConfigurationProperties)
    DISPATCH(xrEnumerateViewConfigurationViews)
    DISPATCH(xrEnumerateEnvironmentBlendModes)
    if (inst->metal) { DISPATCH(xrGetMetalGraphicsRequirementsKHR) }
    DISPATCH(xrCreateSession)
    DISPATCH(xrDestroySession)
    DISPATCH(xrPollEvent)
    DISPATCH(xrBeginSession)
    DISPATCH(xrEndSession)
    DISPATCH(xrRequestExitSession)
    DISPATCH(xrEnumerateReferenceSpaces)
    DISPATCH(xrCreateReferenceSpace)
    DISPATCH(xrDestroySpace)
    DISPATCH(xrLocateSpace)
    DISPATCH(xrGetReferenceSpaceBoundsRect)
    DISPATCH(xrEnumerateSwapchainFormats)
    DISPATCH(xrCreateSwapchain)
    DISPATCH(xrDestroySwapchain)
    DISPATCH(xrEnumerateSwapchainImages)
    DISPATCH(xrAcquireSwapchainImage)
    DISPATCH(xrWaitSwapchainImage)
    DISPATCH(xrReleaseSwapchainImage)
    DISPATCH(xrWaitFrame)
    DISPATCH(xrBeginFrame)
    DISPATCH(xrLocateViews)
    DISPATCH(xrEndFrame)
    DISPATCH(xrResultToString)
    DISPATCH(xrStructureTypeToString)
#undef DISPATCH
    return XR_ERROR_FUNCTION_UNSUPPORTED;
}
} // extern "C"
