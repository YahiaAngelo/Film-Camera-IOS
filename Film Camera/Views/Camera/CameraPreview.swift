//
//  CameraPreview.swift
//  Film Camera
//

import MetalKit
import SwiftUI

/// Live, film-processed camera preview backed by an `MTKView`.
struct CameraPreview: UIViewRepresentable {
    let renderer: FilmRenderer
    /// Invisible layer the rotation coordinator reads the interface orientation from.
    let rotationReferenceLayer: CALayer

    func makeCoordinator() -> Coordinator { Coordinator(renderer: renderer) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = FilmRenderer.previewPixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 30
        view.autoResizeDrawable = true
        view.contentMode = .scaleAspectFill
        view.backgroundColor = .black
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        view.delegate = context.coordinator
        rotationReferenceLayer.frame = CGRect(x: 0, y: 0, width: 1, height: 1)
        view.layer.addSublayer(rotationReferenceLayer)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    final class Coordinator: NSObject, MTKViewDelegate {
        let renderer: FilmRenderer

        init(renderer: FilmRenderer) {
            self.renderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        func draw(in view: MTKView) {
            renderer.draw(in: view)
        }
    }
}
