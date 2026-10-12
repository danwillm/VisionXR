// Add this file to a visionOS App target in Xcode. The bridge itself is built
// with CMake and linked into the Xcode application as libopenxr_loader.a.
// Expects example.mm in the same app target.
import SwiftUI
import CompositorServices
import Metal

@_silgen_name("xrvision_attach_layer_renderer")
private func attachCompositorRenderer(_ renderer: UnsafeMutableRawPointer)
@_silgen_name("xrvision_detach_layer_renderer")
private func detachCompositorRenderer()
@_silgen_name("xrvision_run_example")
private func runOpenXRExample()

struct VisionXRLayerConfig: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // On a headset use layered stereo where available. In Simulator the
        // compositor typically exposes one view and may not support .layered.
        // The native backend now maps views via their actual texture indices,
        // slices and viewports, so dedicated/shared layouts are also supported.
        let supported = capabilities.supportedLayouts(options: [])
        if supported.contains(.layered) {
            configuration.layout = .layered
        } else if supported.contains(.dedicated) {
            configuration.layout = .dedicated
        } else if supported.contains(.shared) {
            configuration.layout = .shared
        } else {
            preconditionFailure("No compositor layout supported by VisionXR")
        }
        configuration.isFoveationEnabled = false
        configuration.colorFormat = .bgra8Unorm_srgb
        configuration.depthFormat = .depth32Float
    }
}

@main struct VisionXRApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchImmersiveView()
        }
        ImmersiveSpace(id: "VisionXRImmersive") {
            CompositorLayer(configuration: VisionXRLayerConfig()) { renderer in
                // The native bridge takes a strong Objective-C reference here.
                attachCompositorRenderer(Unmanaged.passUnretained(renderer).toOpaque())
                Thread.detachNewThread {
                    runOpenXRExample() // normal blocking OpenXR C++ loop
                    detachCompositorRenderer()
                }
            }
        }.immersionStyle(selection: .constant(.full), in: .full)
    }
}

private struct LaunchImmersiveView: View {
    @Environment(\.openImmersiveSpace) private var openImmersiveSpace
    var body: some View {
        Button("Launch OpenXR bridge demo") {
            Task { _ = await openImmersiveSpace(id: "VisionXRImmersive") }
        }.padding()
    }
}
