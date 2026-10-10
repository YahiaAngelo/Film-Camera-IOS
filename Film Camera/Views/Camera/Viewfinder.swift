//
//  Viewfinder.swift
//  Film Camera
//

import SwiftUI

/// The 3:4 live preview with focus, zoom, grid and film overlays.
struct Viewfinder: View {
    @Environment(CameraModel.self) private var camera
    @Environment(FilmLibrary.self) private var library
    var onFilmTap: () -> Void

    @State private var focusPoint: CGPoint?
    @State private var focusID = 0
    @State private var pinchStartZoom: CGFloat?
    @State private var shutterFlash = false

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if let renderer = camera.renderer {
                    CameraPreview(renderer: renderer, rotationReferenceLayer: camera.rotationReferenceLayer)
                } else {
                    Color.black
                }

                if camera.showsGrid {
                    GridOverlay().allowsHitTesting(false)
                }

                if let focusPoint {
                    FocusIndicator()
                        .position(x: focusPoint.x * size.width, y: focusPoint.y * size.height)
                        .id(focusID)
                        .allowsHitTesting(false)
                }

                statusOverlay

                Color.black
                    .opacity(shutterFlash ? 0.85 : 0)
                    .allowsHitTesting(false)
            }
            .contentShape(.rect)
            .onTapGesture { location in
                let point = CGPoint(x: location.x / size.width, y: location.y / size.height)
                camera.focus(atNormalized: point, previewSize: size)
                focusPoint = point
                focusID += 1
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        let start = pinchStartZoom ?? camera.zoomFactor
                        pinchStartZoom = start
                        camera.setZoom(start * value.magnification, animated: false)
                    }
                    .onEnded { _ in pinchStartZoom = nil }
            )
        }
        .aspectRatio(3 / 4, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 24))
        .overlay(alignment: .top) {
            VStack(spacing: 8) {
                filmChip
                if camera.mode == .super8 {
                    Super8Counter()
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.top, 12)
            .animation(.spring(duration: 0.3), value: camera.mode)
        }
        .overlay(alignment: .bottom) {
            ZoomControl().padding(.bottom, 12)
        }
        .onChange(of: camera.shutterCount) {
            // The shutter blink is for photos; recording has its own indicator.
            guard camera.mode == .photo else { return }
            shutterFlash = true
            withAnimation(.easeOut(duration: 0.3)) { shutterFlash = false }
        }
        .task(id: focusID) {
            guard focusPoint != nil else { return }
            try? await Task.sleep(for: .seconds(1.5))
            withAnimation { focusPoint = nil }
        }
    }

    private var filmChip: some View {
        let film = library.film(id: camera.selectedFilmID)
        return Button(action: onFilmTap) {
            HStack(spacing: 6) {
                Image(systemName: "film")
                    .foregroundStyle(Color.filmPrimary)
                Text(film?.displayName ?? "Original")
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .contentTransition(.opacity)
        .animation(.default, value: camera.selectedFilmID)
    }

    @ViewBuilder
    private var statusOverlay: some View {
        switch camera.status {
        case .unauthorized:
            ContentUnavailableView {
                Label("Camera Access Needed", systemImage: "camera.fill")
            } description: {
                Text("Allow camera access in Settings to start shooting on film.")
            } actions: {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.glassProminent)
            }
            .background(.black)
        case .failed(let message):
            ContentUnavailableView("Camera Unavailable", systemImage: "exclamationmark.triangle", description: Text(message))
                .background(.black)
        case .idle, .running:
            EmptyView()
        }
    }
}

private struct GridOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for i in 1...2 {
                let x = size.width * CGFloat(i) / 3
                let y = size.height * CGFloat(i) / 3
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.white.opacity(0.35)), lineWidth: 0.5)
        }
    }
}

private struct FocusIndicator: View {
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(Color.filmPrimary, lineWidth: 1.5)
            .frame(width: 72, height: 72)
            .scaleEffect(settled ? 1 : 1.4)
            .opacity(settled ? 1 : 0)
            .onAppear {
                withAnimation(.spring(duration: 0.3)) { settled = true }
            }
    }
}

/// Super 8 status: the cartridge footage counter, and the running time while recording.
private struct Super8Counter: View {
    @Environment(CameraModel.self) private var camera
    @State private var blink = false

    var body: some View {
        HStack(spacing: 10) {
            if camera.isRecording {
                Circle()
                    .fill(Color(red: 0.96, green: 0.23, blue: 0.19))
                    .frame(width: 8, height: 8)
                    .opacity(blink ? 0.25 : 1)
                    .animation(.easeInOut(duration: 0.6).repeatForever(), value: blink)
                    .onAppear { blink = true }
                    .onDisappear { blink = false }
                Text(Duration.seconds(camera.recordedDuration), format: .time(pattern: .minuteSecond))
                    .monospacedDigit()
                Text("·").foregroundStyle(.secondary)
            }
            Text("\(camera.feetRemaining) FT")
                .monospacedDigit()
                .foregroundStyle(camera.feetRemaining <= 5 ? Color(red: 0.96, green: 0.23, blue: 0.19) : Color.filmPrimary)
                .contentTransition(.numericText(value: Double(camera.feetRemaining)))
            if !camera.isRecording {
                Text("·").foregroundStyle(.secondary)
                Text("\(camera.super8FrameRate) FPS")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
        .animation(.default, value: camera.feetRemaining)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(camera.isRecording
            ? "Recording, \(Int(camera.recordedDuration)) seconds, \(camera.feetRemaining) feet of film left"
            : "\(camera.feetRemaining) feet of film, \(camera.super8FrameRate) frames per second")
    }
}
