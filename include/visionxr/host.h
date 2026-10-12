#pragma once

// C functions callable by a visionOS SwiftUI app. Link with openxr_loader.
// CompositorLayer must supply its LayerRenderer BEFORE an OpenXR session starts.
// The native runtime retains the renderer until xrvision_detach_layer_renderer.
#ifdef __cplusplus
extern "C" {
#endif

void xrvision_attach_layer_renderer(void *objc_layer_renderer);
void xrvision_detach_layer_renderer(void);

// Configured *nonfoveated* layered drawable size for initial XR view recommendation.
// For now the host supplies it; later this can be obtained from compositor topology.
void xrvision_set_recommended_view_size(unsigned width, unsigned height);

#ifdef __cplusplus
}
#endif
