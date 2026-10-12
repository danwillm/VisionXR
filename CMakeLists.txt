cmake_minimum_required(VERSION 3.24)
project(VisionXR VERSION 0.1.0 LANGUAGES C CXX)

option(VISIONXR_FETCH_OPENXR_HEADERS "Fetch OpenXR-SDK for header-only use" ON)
set(VISIONXR_OPENXR_INCLUDE_DIR "" CACHE PATH "Directory containing openxr/openxr.h (skip FetchContent)")

if(VISIONXR_OPENXR_INCLUDE_DIR)
    set(_xr_headers "${VISIONXR_OPENXR_INCLUDE_DIR}")
elseif(VISIONXR_FETCH_OPENXR_HEADERS)
    include(FetchContent)
    # We include the SDK's installed-source headers only. Do not add_subdirectory()
    # since that would build the real OpenXR loader as well.
    FetchContent_Declare(openxr_sdk
        GIT_REPOSITORY https://github.com/KhronosGroup/OpenXR-SDK.git
        GIT_TAG release-1.1.61
        GIT_SHALLOW TRUE)
    FetchContent_GetProperties(openxr_sdk)
    if(NOT openxr_sdk_POPULATED)
        FetchContent_Populate(openxr_sdk)
    endif()
    set(_xr_headers "${openxr_sdk_SOURCE_DIR}/include")
else()
    find_path(_xr_headers NAMES openxr/openxr.h REQUIRED)
endif()

if(NOT EXISTS "${_xr_headers}/openxr/openxr.h")
    message(FATAL_ERROR "OpenXR headers not found at ${_xr_headers}")
endif()

# The ABI target name deliberately shadows the Khronos SDK's usual library.
# Only one target named openxr_loader may exist in a given CMake build.
add_library(openxr_loader STATIC src/openxr.cpp)
add_library(OpenXR::openxr_loader ALIAS openxr_loader)
target_include_directories(openxr_loader PUBLIC
    $<BUILD_INTERFACE:${_xr_headers}>
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>)
target_include_directories(openxr_loader PRIVATE src)
target_compile_features(openxr_loader PUBLIC cxx_std_17)
target_compile_definitions(openxr_loader PUBLIC XR_USE_GRAPHICS_API_METAL=1 XR_EXTENSION_PROTOTYPES=1)
set_target_properties(openxr_loader PROPERTIES POSITION_INDEPENDENT_CODE ON)

if(CMAKE_SYSTEM_NAME STREQUAL "visionOS" OR CMAKE_SYSTEM_NAME STREQUAL "xrOS")
    enable_language(OBJCXX)
    target_sources(openxr_loader PRIVATE src/apple_backend.mm)
    target_compile_options(openxr_loader PRIVATE $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>)
    target_link_libraries(openxr_loader PUBLIC
        "-framework Foundation" "-framework Metal" "-framework CompositorServices" "-framework ARKit")
    message(STATUS "visionOS backend enabled")
else()
    target_sources(openxr_loader PRIVATE src/stub_backend.cpp)
    message(STATUS "Host stub backend: entrypoints build, sessions cannot start")
endif()

include(CTest)
if(BUILD_TESTING)
    add_executable(visionxr_api_test sample/api_test.cpp)
    target_link_libraries(visionxr_api_test PRIVATE OpenXR::openxr_loader)
    add_test(NAME visionxr_api_test COMMAND visionxr_api_test)
    add_executable(visionxr_renderer_wait_test tests/renderer_wait_test.cpp)
    target_include_directories(visionxr_renderer_wait_test PRIVATE src)
    target_compile_features(visionxr_renderer_wait_test PRIVATE cxx_std_17)
    add_test(NAME visionxr_renderer_wait_test COMMAND visionxr_renderer_wait_test)
    # Exercise the real ABI using a deterministic tracking backend, without Metal.
    add_executable(visionxr_tracking_test tests/tracking_test.cpp src/openxr.cpp)
    target_include_directories(visionxr_tracking_test PRIVATE "${_xr_headers}" include src)
    target_compile_features(visionxr_tracking_test PRIVATE cxx_std_17)
    target_compile_definitions(visionxr_tracking_test PRIVATE XR_USE_GRAPHICS_API_METAL=1 XR_EXTENSION_PROTOTYPES=1)
    add_test(NAME visionxr_tracking_test COMMAND visionxr_tracking_test)
    if(APPLE AND NOT CMAKE_SYSTEM_NAME STREQUAL "visionOS" AND NOT CMAKE_SYSTEM_NAME STREQUAL "xrOS")
        enable_language(OBJCXX)
        add_executable(visionxr_composition_gpu_test tests/composition_gpu_test.mm)
        target_include_directories(visionxr_composition_gpu_test PRIVATE src)
        target_compile_features(visionxr_composition_gpu_test PRIVATE cxx_std_17)
        target_compile_options(visionxr_composition_gpu_test PRIVATE -fobjc-arc)
        target_link_libraries(visionxr_composition_gpu_test PRIVATE "-framework Foundation" "-framework Metal")
        add_test(NAME visionxr_composition_gpu_test COMMAND visionxr_composition_gpu_test)
        set_tests_properties(visionxr_composition_gpu_test PROPERTIES SKIP_RETURN_CODE 77)
    endif()
endif()
