//
//  FilmCameraApp.swift
//  Film Camera
//

import SwiftUI

@main
struct FilmCameraApp: App {
    @State private var camera = CameraModel()
    @State private var library = FilmLibrary()

    init() {
        // Film thumbnails come from GitHub; keep them around for offline browsing.
        URLCache.shared = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 256 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .environment(camera)
                .environment(library)
                .tint(.filmPrimary)
        }
    }
}
