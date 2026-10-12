#pragma once
#include <openxr/openxr.h>
#include <cstdint>
#include <array>
#include <vector>

namespace backend {
struct HeadLocation {
    XrPosef worldFromHead{{0, 0, 0, 1}, {0, 0, 0}};
    XrSpaceLocationFlags flags = 0;
};
struct Frame {
    void* opaque = nullptr;
    void* timing = nullptr;
    void* drawables = nullptr;
    uint64_t optimalMachTicks = 0;
    XrTime displayTimeNs = 0;
    bool startedSubmission = false;
    HeadLocation head;
};
struct View {
    XrPosef eyeFromHead{};
    XrFovf fov{};
    bool available = false;
};
struct Copy {
    void* texture = nullptr;      // retained id<MTLTexture> owned by swapchain
    uint32_t srcSlice = 0;
    XrRect2Di rect{};
};
constexpr uint32_t maxLayers = 16;
struct Layer {
    enum class Type { Projection, Quad } type = Type::Projection;
    XrCompositionLayerFlags flags = 0;
    std::array<Copy, 2> images{};
    XrEyeVisibility eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    bool headRelative = false;
    XrPosef originFromQuad{{0, 0, 0, 1}, {0, 0, 0}};
    XrExtent2Df size{};
};
void attach(void* renderer);
void detach();
bool ready();
void* device();
bool configureQueue(void* commandQueue);
uint32_t viewCount();
XrTime now();
HeadLocation locateHead(XrTime time);
XrResult createImage(uint32_t width, uint32_t height, uint32_t layers, int64_t format, void** image);
void destroyImage(void* image);
XrResult waitFrame(Frame& frame);
XrResult beginFrame(Frame& frame, std::vector<View>& views);
XrResult endFrame(Frame& frame, const std::vector<Layer>& layers);
}
