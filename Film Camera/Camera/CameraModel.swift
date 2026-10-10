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

    enum CaptureMode: String, CaseIterable, Identifiable {
        case photo, super8
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photo: "Photo"
            case .super8: "Super 8"
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

    // MARK: Super 8 state

    private(set) var mode: CaptureMode = CaptureMode(rawValue: UserDefaults.standard.string(forKey: Keys.mode) ?? "") ?? .photo
    /// Super 8 cameras ran at 18 fps (silent) or 24 fps (sound).
    private(set) var super8FrameRate: Int = UserDefaults.standard.integer(forKey: Keys.frameRate) == 24 ? 24 : 18
    private(set) var isRecording = false
    private(set) var isFinishingRecording = false
    /// Frames recorded in the current clip.
    private(set) var recordedFrames = 0

    var recordedDuration: TimeInterval { Double(recordedFrames) / Double(super8FrameRate) }
    /// Film left in the 50 ft cartridge.
    var feetRemaining: Int {
        max(0, Super8Recorder.cartridgeFeet - recordedFrames / Super8Recorder.framesPerFoot)
    }

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
        static let mode = "captureMode"
        static let frameRate = "super8FrameRate"
    }

    let renderer: FilmRenderer?
    private let service = CameraService()
    private let recorder: Super8Recorder?

    /// An invisible, unconnected preview layer that lives in the view hierarchy
    /// so the rotation coordinator knows the interface orientation.
    let rotationReferenceLayer: AVCaptureVideoPreviewLayer
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    /// Current rotation applied to preview frames, used to map taps to the sensor.
    private var previewRotationAngle: CGFloat = 90

    #if targetEnvironment(simulator)
    private var simulatorFrame: CVPixelBuffer?
    private var simulatorFeed: Task<Void, Never>?
    #endif

    init() {
        let renderer = FilmRenderer()
        let recorder = renderer.map { Super8Recorder(renderer: $0) }
        self.renderer = renderer
        self.recorder = recorder
        rotationReferenceLayer = AVCaptureVideoPreviewLayer(sessionWithNoConnection: service.session)
        // Every camera frame goes to the preview and, while recording, into the clip.
        service.onFrame = Self.makeFrameHandler(renderer: renderer, recorder: recorder)
        service.onAudio = Self.makeAudioHandler(recorder: recorder)
        recorder?.onFrameWritten = { @Sendable [weak self] count in
            Task { @MainActor [weak self] in self?.recorderWroteFrame(count) }
        }
        renderer?.setAdjustments(adjustments)
        renderer?.setSuper8(mode == .super8)
    }

    // Built outside the main actor: these run on the capture queues, and the
    // renderer and recorder they call are thread-safe.
    private nonisolated static func makeFrameHandler(renderer: FilmRenderer?, recorder: Super8Recorder?)
        -> @Sendable (CVPixelBuffer, CMTime) -> Void {
        { frame, time in
            renderer?.enqueue(frame: frame)
            recorder?.appendVideo(frame, time: time)
        }
    }

    private nonisolated static func makeAudioHandler(recorder: Super8Recorder?) -> @Sendable (CMSampleBuffer) -> Void {
        { sample in recorder?.appendAudio(sample) }
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
            await configureServiceForMode()
        } catch {
            status = .failed(error.localizedDescription)
        }
        #endif
    }

    func stop() {
        #if targetEnvironment(simulator)
        simulatorFeed?.cancel()
        simulatorFeed = nil
        #endif
        service.stop()
        if status == .running { status = .idle }
    }

    // MARK: - Mode

    func setMode(_ newMode: CaptureMode) async {
        guard newMode != mode, !isRecording else { return }
        mode = newMode
        UserDefaults.standard.set(newMode.rawValue, forKey: Keys.mode)
        renderer?.setSuper8(newMode == .super8)
        await configureServiceForMode()
    }

    func toggleSuper8FrameRate() async {
        guard !isRecording else { return }
        super8FrameRate = super8FrameRate == 18 ? 24 : 18
        UserDefaults.standard.set(super8FrameRate, forKey: Keys.frameRate)
        await configureServiceForMode()
    }

    /// Sets the camera frame rate and microphone for the current mode.
    private func configureServiceForMode() async {
        #if targetEnvironment(simulator)
        startSimulatorFeed()
        #else
        guard status == .running else { return }
        if mode == .super8 {
            let recordsAudio = await CameraService.requestAccess(for: .audio)
            await service.configureVideoMode(frameRate: super8FrameRate, recordsAudio: recordsAudio)
        } else {
            await service.configureVideoMode(frameRate: nil, recordsAudio: false)
        }
        #endif
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

    // MARK: - Super 8 recording

    func toggleRecording() async {
        if isRecording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard mode == .super8, !isRecording, !isFinishingRecording, let recorder, let renderer,
              let frameSize = renderer.latestFrameSize
        else { return }

        // 4:3, 1440 px on the long side, like a good Super 8 scan.
        let longSide: CGFloat = 1440
        let scale = longSide / max(frameSize.width, frameSize.height)
        let size = CGSize(width: (frameSize.width * scale / 2).rounded() * 2,
                          height: (frameSize.height * scale / 2).rounded() * 2)
        let url = FileManager.default.temporaryDirectory.appending(path: "Super8-\(UUID().uuidString).mov")

        do {
            #if targetEnvironment(simulator)
            let audioSettings: [String: Any]? = nil
            #else
            let audioSettings = await service.recommendedAudioSettings()
            #endif
            try recorder.start(url: url, size: size, transform: recordingTransform(),
                               frameRate: super8FrameRate, audioSettings: audioSettings)
            renderer.beginClip()
            recordedFrames = 0
            isRecording = true
            shutterCount += 1
        } catch {
            captureError = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard isRecording, let recorder else { return }
        isRecording = false
        isFinishingRecording = true
        shutterCount += 1
        renderer?.endClip()
        defer { isFinishingRecording = false }

        do {
            let url = try await recorder.finish()
            lastPhoto = await Self.thumbnail(forVideoAt: url)
            try await PhotoWriter.saveVideoToLibrary(url)
        } catch Super8Recorder.RecorderError.noFrames {
            // Tapped start and stop immediately; nothing to save.
        } catch {
            captureError = error.localizedDescription
        }
    }

    private func recorderWroteFrame(_ count: Int) {
        guard isRecording else { return }
        recordedFrames = count
        // The cartridge has run out.
        if count >= Super8Recorder.cartridgeFrames {
            Task { await stopRecording() }
        }
    }

    /// Rotates the clip for playback when the phone is held sideways. Preview
    /// frames are always upright for the portrait UI.
    private func recordingTransform() -> CGAffineTransform {
        guard let capture = rotationCoordinator?.videoRotationAngleForHorizonLevelCapture else { return .identity }
        var degrees = (capture - previewRotationAngle).truncatingRemainder(dividingBy: 360)
        if degrees < 0 { degrees += 360 }
        // Mirrored selfie frames rotate the other way.
        if position == .front { degrees = (360 - degrees).truncatingRemainder(dividingBy: 360) }
        return CGAffineTransform(rotationAngle: degrees * .pi / 180)
    }

    private static func thumbnail(forVideoAt url: URL) async -> UIImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 240, height: 240)
        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: image)
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
        deviceInfo = CameraDeviceInfo(device: nil, position: .back, zoomStops: [1, 2, 4], displayMultiplier: 0.5,
                                      minZoom: 1, maxZoom: 30, defaultZoom: 2, hasFlash: true)
        zoomFactor = 2
        status = .running

        // Deliver the still scene at the capture frame rate, like a camera would.
        simulatorFeed?.cancel()
        let fps = mode == .super8 ? super8FrameRate : 30
        guard let handler = service.onFrame else { return }
        simulatorFeed = Task.detached(priority: .userInitiated) {
            let clock = CMClockGetHostTimeClock()
            while !Task.isCancelled {
                handler(frame, CMClockGetTime(clock))
                try? await Task.sleep(for: .seconds(1.0 / Double(fps)))
            }
        }
    }
    #endif
}
