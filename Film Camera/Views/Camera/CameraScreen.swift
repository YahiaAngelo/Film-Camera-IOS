//
//  CameraScreen.swift
//  Film Camera
//

import SwiftUI

struct CameraScreen: View {
    @Environment(CameraModel.self) private var camera
    @Environment(FilmLibrary.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    @State private var showsLibrary = false
    @State private var showsAdjustments = false

    var body: some View {
        VStack(spacing: 12) {
            topBar
                .padding(.horizontal)
            Viewfinder(onFilmTap: { showsLibrary = true })
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            FilmStrip(onBrowse: { showsLibrary = true })
            // The mode switcher also separates the film strip from the shutter,
            // and the extra bottom padding lifts the shutter to where thumbs rest.
            ModePicker()
            bottomBar
                .padding(.horizontal, 28)
                .padding(.bottom, 28)
        }
        .padding(.top, 4)
        .background(Color.black.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $showsLibrary) {
            FilmLibraryView()
        }
        .sheet(isPresented: $showsAdjustments) {
            AdjustmentsSheet()
        }
        .alert("Something Went Wrong", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(camera.captureError ?? library.errorMessage ?? "")
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: camera.shutterCount)
        .task {
            let film = library.film(id: camera.selectedFilmID)
            await camera.selectFilm(film, lutURL: film.flatMap { library.lutURL(for: $0) })
            await camera.start()
            await library.refreshCatalog()
        }
        #if DEBUG
        .onAppear {
            // For App Store screenshot automation: `-FCOpenSheet library|adjustments`.
            switch UserDefaults.standard.string(forKey: "FCOpenSheet") {
            case "library": showsLibrary = true
            case "adjustments": showsAdjustments = true
            default: break
            }
        }
        #endif
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: Task { await camera.start() }
            case .background:
                Task {
                    await camera.stopRecording()
                    camera.stop()
                }
            default: break
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        @Bindable var camera = camera
        return HStack(spacing: 12) {
            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    if camera.mode == .super8 {
                        Button {
                            Task { await camera.toggleSuper8FrameRate() }
                        } label: {
                            Text("\(camera.super8FrameRate)")
                                .font(.system(size: 15, weight: .bold).monospacedDigit())
                                .foregroundStyle(Color.filmPrimary)
                                .contentTransition(.numericText(value: Double(camera.super8FrameRate)))
                                .frame(width: 44, height: 44)
                                .contentShape(.circle)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: .circle)
                        .disabled(camera.isRecording)
                        .accessibilityLabel("\(camera.super8FrameRate) frames per second")
                        .accessibilityHint("Switches between 18 and 24 frames per second")
                    } else if camera.deviceInfo?.hasFlash ?? false {
                        glassIcon(camera.flashMode.systemImage, label: "Flash \(camera.flashMode.title)",
                                  isOn: camera.flashMode != .off) {
                            let modes = CameraModel.FlashMode.allCases
                            let index = modes.firstIndex(of: camera.flashMode) ?? 0
                            camera.flashMode = modes[(index + 1) % modes.count]
                        }
                    }
                    glassIcon("grid", label: "Grid", isOn: camera.showsGrid) {
                        camera.showsGrid.toggle()
                    }
                }
            }

            Spacer()

            GlassEffectContainer(spacing: 12) {
                HStack(spacing: 12) {
                    glassIcon("slider.horizontal.3", label: "Adjustments", isOn: camera.adjustments != .default) {
                        showsAdjustments = true
                    }
                    glassIcon("film.stack", label: "Film Library", isOn: false) {
                        showsLibrary = true
                    }
                }
            }
        }
        .frame(height: 48)
    }

    private func glassIcon(_ systemImage: String, label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? Color.filmPrimary : .white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    // MARK: - Bottom bar

    private var bottomBar: some View {
        HStack {
            Button {
                openURL(URL(string: "photos-redirect://")!)
            } label: {
                Group {
                    if let photo = camera.lastPhoto {
                        Image(uiImage: photo).resizable().scaledToFill()
                    } else {
                        Color.filmSurfaceContainerHigh
                            .overlay { Image(systemName: "photo.on.rectangle").foregroundStyle(.secondary) }
                    }
                }
                .frame(width: 54, height: 54)
                .clipShape(.rect(cornerRadius: 12))
                .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.2)) }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Photos")

            Spacer()

            ShutterButton(style: shutterStyle, isBusy: camera.isCapturing || camera.isFinishingRecording) {
                Task {
                    switch camera.mode {
                    case .photo: await camera.capture()
                    case .super8: await camera.toggleRecording()
                    }
                }
            }
            .disabled(camera.status != .running)

            Spacer()

            Button {
                Task { await camera.flipCamera() }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 54, height: 54)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
            .disabled(camera.isRecording)
            .opacity(camera.isRecording ? 0.4 : 1)
            .accessibilityLabel("Switch Camera")
        }
    }

    private var shutterStyle: ShutterButton.Style {
        switch camera.mode {
        case .photo: .photo
        case .super8: camera.isRecording ? .recording : .record
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            // Library errors are shown inside the library sheet while it's open.
            camera.captureError != nil || (!showsLibrary && library.errorMessage != nil)
        } set: { isPresented in
            if !isPresented {
                camera.captureError = nil
                library.errorMessage = nil
            }
        }
    }
}

#Preview {
    CameraScreen()
        .environment(CameraModel())
        .environment(FilmLibrary())
}
