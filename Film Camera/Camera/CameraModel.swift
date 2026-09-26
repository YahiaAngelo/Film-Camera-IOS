//
//  CameraModel.swift
//  Film Camera
//

import AVFoundation
import Observation
import UIKit

/// UI-facing camera state. Bridges SwiftUI to `CameraService` and `FilmRenderer`.
@Observable
final class CameraModel {
    enum Status: Equatable {
        case idle
        case running
        case unauthorized
        case failed(String)
    }

    enum FlashMode: String, CaseIterable, Identifiable {
        case off, auto, on
        var id: String { rawValue }

        var systemImage: String {
            switch self {
            case .off: "bolt.slash.fill"
            case .auto: "bolt.badge.automatic.fill"
            case .on: "bolt.fill"
            }
        }

        var title: String { rawValue.capitalized }

        var avMode: AVCaptureDevice.FlashMode {
            switch self {
            case .off: .off
            case .auto: .auto
            case .on: .on
            }
        }
    }

    private(set) var status: Status = .idle
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var deviceInfo: CameraDeviceInfo?
    /// Current device zoom factor.
    private(set) var zoomFactor: CGFloat = 1
    private(set) var lastPhoto: UIImage?
    private(set) var isCapturing = false
    /// Incremented on every shutter press; drives haptics and the shutter flash.
    private(set) var shutterCount = 0
    var captureError: String?

    var flashMode: FlashMode = .off
    var showsGrid = false

    /// The film currently loaded into the renderer (`nil` = no film).
    private(set) var selectedFilmID: String? = UserDefaults.standard.string(forKey: Keys.selectedFilm)

    var adjustments: FilmAdjustments = CameraModel.savedAdjustments() {
        didSet {
            renderer?.setAdjustments(adjustments)
            if let data = try? JSONEncoder().encode(adjustments) {
                UserDefaults.standard.set(data, forKey: Keys.adjustments)
            }
        }
    }

    private enum Keys {
        static let selectedFilm = "selectedFilm"
        static let adjustments = "adjustments"
    }

    let renderer: FilmRenderer?
    private let service = CameraService()

    /// An invisible, unconnected preview layer that lives in the view hierarchy
    /// so the rotation coordinator knows the interface orientation.
    let rotationReferenceLayer: AVCaptureVideoPreviewLayer
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Current rotation applied to preview frames, used to map taps to the sensor.
    private var previewRotationAngle: CGFloat = 90

    #if targetEnvironment(simulator)
    private var simulatorFrame: CVPixelBuffer?
    #endif

    init() {
        renderer = FilmRenderer()
        rotationReferenceLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: service.session)
        let renderer = renderer
        service.onFrame = { frame in renderer?.enqueue(frame: frame) }
        renderer?.setAdjustments(adjustments)
    }

    private static func savedAdjustments() -> FilmAdjustments {
        guard let data = UserDefaults.standard.data(forKey: Keys.adjustments),
              let value = try? JSONDecoder().decode(FilmAdjustments.self, from: data)
        else { return .default }
        return value
    }

    // MARK: - Film

    /// Loads a film's LUT into the renderer. Pass `nil` for no film.
    func selectFilm(_ film: Film?, lutURL: URL?) async {
        selectedFilmID = film?.id
        UserDefaults.standard.set(film?.id, forKey: Keys.selectedFilm)
        guard let film, let lutURL else {
            renderer?.setLUT(nil)
            return
        }
        do {
            let cube = try await Task.detached(priority: .userInitiated) { try CubeLUT(contentsOf: lutURL) }.value
            // Ignore stale loads if the user already picked another film.
            guard selectedFilmID == film.id else { return }
            renderer?.setLUT(cube)
        } catch {
            captureError = "Couldn't load \(film.displayName). \(error.localizedDescription)"
        }
    }

    var displayZoom: CGFloat { zoomFactor * (deviceInfo?.displayMultiplier ?? 1) }

    // MARK: - Lifecycle

    func start() async {
        guard status != .running else { return }
        guard renderer != nil else {
            status = .failed("Metal is not available on this device.")
            return
        }

        #if targetEnvironment(simulator)
        startSimulatorFeed()
        #else
        guard await CameraService.requestAccess() else {
            status = .unauthorized
            return
        }
        do {
            apply(try await service.start(position: position))
            status = .running
        } catch {
            status = .failed(error.localizedDescription)
        }
        #endif
    }

    func stop() {
        service.stop()
        if status == .running { status = .idle }
    }

    func flipCamera() async {
        guard status == .running, deviceInfo != nil else { return }
        let next: AVCaptureDevice.Position = position == .back ? .front : .back
        do {
            apply(try await service.switchCamera(to: next))
        } catch {
            captureError = error.localizedDescription
        }
    }

    private func apply(_ info: CameraDeviceInfo) {
        deviceInfo = info
        position = info.position
        zoomFactor = info.defaultZoom
        if let device = info.device { observeRotation(of: device) }
    }

    /// Keeps preview frames upright for this camera. The angle differs between
    /// cameras because their sensors are mounted differently.
    private func observeRotation(of device: AVCaptureDevice) {
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: rotationReferenceLayer)
        rotationCoordinator = coordinator
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { @Sendable [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in self?.updatePreviewRotation(angle) }
        }
    }

    private func updatePreviewRotation(_ angle: CGFloat) {
        previewRotationAngle = angle
        service.setPreviewRotation(angle)
    }

    // MARK: - Controls

    func setZoom(_ factor: CGFloat, animated: Bool = true) {
        guard let info = deviceInfo else { return }
        zoomFactor = min(max(factor, info.minZoom), info.maxZoom)
        service.setZoom(zoomFactor, animated: animated)
    }

    /// Focus on a point given in normalized preview coordinates (0...1, top-left origin).
    func focus(atNormalized point: CGPoint, previewSize: CGSize) {
        guard deviceInfo != nil, let frameSize = renderer?.latestFrameSize else { return }

        // Undo the preview's aspect-fill crop to get a point in the portrait frame.
        let scale = max(previewSize.width / frameSize.width, previewSize.height / frameSize.height)
        let visibleU = previewSize.width / (frameSize.width * scale)
        let visibleV = previewSize.height / (frameSize.height * scale)
        let u = (1 - visibleU) / 2 + point.x * visibleU
        let v = (1 - visibleV) / 2 + point.y * visibleV

        service.focus(at: Self.sensorPoint(u: u, v: v, rotation: previewRotationAngle, mirrored: position == .front))
    }

    /// Maps a point in the delivered (rotated, possibly mirrored) frame back to
    /// the unrotated sensor image that focus/exposure points of interest use.
    static func sensorPoint(u: CGFloat, v: CGFloat, rotation: CGFloat, mirrored: Bool) -> CGPoint {
        let u = mirrored ? 1 - u : u
        switch Int(rotation.rounded()) % 360 {
        case 90: return CGPoint(x: v, y: 1 - u)
        case 180: return CGPoint(x: 1 - u, y: 1 - v)
        case 270: return CGPoint(x: 1 - v, y: u)
        default: return CGPoint(x: u, y: v)
        }
    }

    // MARK: - Capture

    func capture() async {
        guard !isCapturing, let renderer else { return }
        isCapturing = true
        shutterCount += 1
        defer { isCapturing = false }

        do {
            let photo = try await capturePhoto()
            let (data, preview) = try await Task.detached(priority: .userInitiated) {
                guard let image = renderer.renderPhoto(photo.pixelBuffer) else { throw PhotoWriter.WriteError.encodingFailed }
                let data = try PhotoWriter.encode(image, metadata: photo.metadata)
                let orientation = PhotoWriter.orientation(from: photo.metadata)
                let preview = UIImage(cgImage: image, scale: 1, orientation: orientation)
                    .preparingThumbnail(of: CGSize(width: 240, height: 240 * CGFloat(image.width) / CGFloat(image.height)))
                return (data, preview)
            }.value
            lastPhoto = preview
            try await PhotoWriter.saveToLibrary(data)
        } catch {
            captureError = error.localizedDescription
        }
    }

    private func capturePhoto() async throws -> CapturedPhoto {
        #if targetEnvironment(simulator)
        guard let frame = simulatorFrame else { throw CameraError.noCamera }
        return CapturedPhoto(pixelBuffer: frame, metadata: [:])
        #else
        return try await service.capturePhoto(flash: flashMode.avMode,
                                              rotationAngle: rotationCoordinator?.videoRotationAngleForHorizonLevelCapture)
        #endif
    }

    // MARK: - Simulator

    #if targetEnvironment(simulator)
    /// The simulator has no camera, so feed a still scene through the pipeline.
    private func startSimulatorFeed() {
        guard let image = UIImage(named: "SampleScene.jpg")?.cgImage,
              let frame = PixelBufferFactory.make(from: image, size: CGSize(width: 1080, height: 1440))
        else {
            status = .failed("Sample scene missing.")
            return
        }
        simulatorFrame = frame
        renderer?.enqueue(frame: frame)
        deviceInfo = CameraDeviceInfo(device: nil, position: .back, zoomStops: [1, 2, 4], displayMultiplier: 0.5,
                                      minZoom: 1, maxZoom: 30, defaultZoom: 2, hasFlash: true)
        zoomFactor = 2
        status = .running
    }
    #endif
}
