#include "backend.hpp"
#include <chrono>
namespace backend {
void attach(void*) {} void detach() {} bool ready() { return false; }
void* device() { return nullptr; }
bool configureQueue(void*) { return false; }
uint32_t viewCount() { return 2; }
XrTime now() { return std::chrono::duration_cast<std::chrono::nanoseconds>(
    std::chrono::steady_clock::now().time_since_epoch()).count(); }
HeadLocation locateHead(XrTime) { return {}; }
XrResult createImage(uint32_t,uint32_t,uint32_t,int64_t,void**) { return XR_ERROR_RUNTIME_UNAVAILABLE; }
void destroyImage(void*) {}
XrResult waitFrame(Frame&) { return XR_ERROR_SESSION_NOT_RUNNING; }
XrResult beginFrame(Frame&,std::vector<View>&) { return XR_ERROR_SESSION_NOT_RUNNING; }
XrResult endFrame(Frame&,const std::vector<Layer>&) { return XR_ERROR_SESSION_NOT_RUNNING; }
}
extern "C" {
void xrvision_attach_layer_renderer(void*) {}
void xrvision_detach_layer_renderer() {}
}
