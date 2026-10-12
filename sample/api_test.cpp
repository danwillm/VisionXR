#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>
#include <cassert>
#include <cstring>
#include <cstdio>
int main() {
    PFN_xrVoidFunction proc = nullptr;
    assert(xrGetInstanceProcAddr(XR_NULL_HANDLE,"xrCreateInstance",&proc) == XR_SUCCESS);
    assert(proc != nullptr);
    assert(xrGetInstanceProcAddr(XR_NULL_HANDLE,"xrNoSuchFunction",&proc) == XR_ERROR_FUNCTION_UNSUPPORTED);
    uint32_t n = 0;
    assert(xrEnumerateInstanceExtensionProperties(nullptr,0,&n,nullptr) == XR_SUCCESS);
    assert(n == 1);
    XrExtensionProperties ext{XR_TYPE_EXTENSION_PROPERTIES};
    assert(xrEnumerateInstanceExtensionProperties(nullptr,1,&n,&ext) == XR_SUCCESS);
    assert(std::strcmp(ext.extensionName,"XR_KHR_metal_enable") == 0);
    std::puts("OpenXR symbol dispatch + Metal extension enumeration: OK");
}
