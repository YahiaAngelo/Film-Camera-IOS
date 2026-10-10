//
//  CameraService.swift
//  Film Camera
//

@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Describes the active capture device, for building the zoom controls.
nonisolated struct CameraDeviceInfo: @unchecked Sendable {
    /// `nil` for the simulator's stand-in camera.
    var device: AVCaptureDevice?
    var position: AVCaptureDevice.Position
    /// Device zoom factors for the lens buttons (e.g. ultra wide, wide, tele).
    var zoomStops: [CGFloat]
    /// Multiply a device zoom factor by this to get the "0.5×/1×/2×" label.
    var displayMultiplier: CGFloat
    var minZoom: CGFloat
    var maxZoom: CGFloat
    var defaultZoom: CGFloat
    var hasFlash: Bool
}

/// An uncompressed BGRA photo and its capture metadata (EXIF, orientation…).
nonisolated struct CapturedPhoto: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let metadata: [String: Any]
}

nonisolated enum CameraError: LocalizedError {
    case noCamera
    case cannotAddInput
    case cannotAddOutput
    case noPhotoData

    var errorDescription: String? {
        switch self {
        case .noCamera: "No camera is available on this device."
        case .cannotAddInput: "The camera could not be opened."
        case .cannotAddOutput: "The camera output could not be configured."
        case .noPhotoData: "The camera did not return a photo."
        }
    }
}

/// Owns the `AVCaptureSession`. All session work happens on a private serial
/// queue; preview frames are delivered on a high-priority video queue.
nonisolated final class CameraService: NSObject, @unchecked Sendable,
                                       AVCaptureVideoDataOutputSampleBufferDelegate,
                                       AVCaptureAudioDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()

    /// Called on the video queue for every preview frame (upright portrait, BGRA),
    /// with its presentation time.
    var onFrame: (@Sendable (CVPixelBuffer, CMTime) -> Void)?
    /// Called on the audio queue with microphone samples while audio is enabled.
    var onAudio: (@Sendable (CMSampleBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "FilmCamera.session")
    private let videoQueue = DispatchQueue(label: "FilmCamera.video", qos: .userInteractive)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let audioQueue = DispatchQueue(label: "FilmCamera.audio")
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioInput: AVCaptureDeviceInput?
    /// Fixed capture frame rate for Super 8 mode; `nil` uses the format default.
    private var targetFrameRate: Int?
    private var deviceInput: AVCaptureDeviceInput?
    private var isConfigured = false
    /// Rotation that makes preview frames upright; set by `CameraModel` from the
    /// device's `RotationCoordinator`, since sensors are mounted differently per
    /// camera (e.g. the iPhone 17 front camera needs 0°, the back camera 90°).
    private var previewRotationAngle: CGFloat = 90

    private let lock = NSLock()
    private var inFlightCaptures: [Int64: PhotoCaptureDelegate] = [:]

    static func requestAccess(for mediaType: AVMediaType = .video) async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: mediaType)
        default: false
        }
    }

    // MARK: - Session lifecycle

    func start(position: AVCaptureDevice.Position) async throws -> CameraDeviceInfo {
        try await onSessionQueue {
            if !self.isConfigured {
                try self.configureSession(position: position)
                self.configureVideoConnection()
                self.isConfigured = true
            }
            if !self.session.isRunning { self.session.startRunning() }
            return try self.currentDeviceInfo()
        }
    }

    func stop() {
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
        }
    }

    func switchCamera(to position: AVCaptureDevice.Position) async throws -> CameraDeviceInfo {
        try await onSessionQueue {
            guard let device = Self.bestDevice(for: position) else { throw CameraError.noCamera }
            self.session.beginConfiguration()
            let previousInput = self.deviceInput
            if let previousInput { self.session.removeInput(previousInput) }
            do {
                try self.attach(device: device)
            } catch {
                // Put the old camera back so the session keeps running.
                if let previousInput, self.session.canAddInput(previousInput) {
                    self.session.addInput(previousInput)
                    self.deviceInput = previousInput
                }
                self.session.commitConfiguration()
                self.configureVideoConnection()
                throw error
            }
            self.session.commitConfiguration()
            self.configureVideoConnection()
            return try self.currentDeviceInfo()
        }
    }

    private func configureSession(position: AVCaptureDevice.Position) throws {
        guard let device = Self.bestDevice(for: position) else { throw CameraError.noCamera }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo
        // LUTs are authored for sRGB input; keep the whole pipeline in sRGB.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        guard session.canAddOutput(videoOutput), session.canAddOutput(photoOutput) else { throw CameraError.cannotAddOutput }
        session.addOutput(videoOutput)
        session.addOutput(photoOutput)
        photoOutput.maxPhotoQualityPrioritization = .quality

        try attach(device: device)
    }

    /// Adds the device input and re-applies per-device connection settings.
    /// Must be called on the session queue, inside a configuration block.
    private func attach(device: AVCaptureDevice) throws {
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CameraError.cannotAddInput }
        session.addInput(input)
        deviceInput = input

        try device.lockForConfiguration()
        if device.activeFormat.supportedColorSpaces.contains(.sRGB) {
            device.activeColorSpace = .sRGB
        }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.videoZoomFactor = Self.defaultZoom(for: device)
        Self.apply(frameRate: targetFrameRate, to: device)
        device.unlockForConfiguration()

        // 12 MP keeps full-resolution Metal processing fast and memory friendly.
        let dimensions = device.activeFormat.supportedMaxPhotoDimensions
        let preferred = dimensions
            .filter { Int($0.width) * Int($0.height) <= 12_200_000 }
            .max { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }
        if let chosen = preferred ?? dimensions.first {
            photoOutput.maxPhotoDimensions = chosen
        }
    }

    /// Applies the preview rotation and selfie mirroring to the video output.
    /// Must run after `commitConfiguration()`: when inputs are swapped, the
    /// output's new connection isn't reliably formed until the commit.
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(previewRotationAngle) {
            connection.videoRotationAngle = previewRotationAngle
        }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = deviceInput?.device.position == .front
        }
    }

    func setPreviewRotation(_ angle: CGFloat) {
        sessionQueue.async {
            guard angle != self.previewRotationAngle || self.videoOutput.connection(with: .video)?.videoRotationAngle != angle else { return }
            self.previewRotationAngle = angle
            self.configureVideoConnection()
        }
    }

    private func currentDeviceInfo() throws -> CameraDeviceInfo {
        guard let device = deviceInput?.device else { throw CameraError.noCamera }
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        let multiplier: CGFloat = hasUltraWide ? 0.5 : 1
        let maxZoom = min(device.maxAvailableVideoZoomFactor, 15 / multiplier)

        var stops: [CGFloat] = [device.minAvailableVideoZoomFactor]
        stops += device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
        // Offer a 2× crop when there's no dedicated telephoto lens.
        let twoX = 2 / multiplier
        if !stops.contains(where: { abs($0 * multiplier - 2) < 0.3 || $0 * multiplier > 2 }), twoX <= maxZoom {
            stops.append(twoX)
        }

        return CameraDeviceInfo(
            device: device,
            position: device.position,
            zoomStops: stops.filter { $0 <= maxZoom },
            displayMultiplier: multiplier,
            minZoom: device.minAvailableVideoZoomFactor,
            maxZoom: maxZoom,
            defaultZoom: Self.defaultZoom(for: device),
            hasFlash: device.hasFlash
        )
    }

    private static func bestDevice(for position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
        return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position).devices.first
    }

    /// The wide lens ("1×") on virtual devices that start at the ultra wide.
    private static func defaultZoom(for device: AVCaptureDevice) -> CGFloat {
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        guard hasUltraWide, let first = device.virtualDeviceSwitchOverVideoZoomFactors.first else { return 1 }
        return CGFloat(truncating: first)
    }

    // MARK: - Super 8

    /// Switches between photo and Super 8 capture: fixes the camera's frame rate
    /// (a real low frame rate, with the longer exposure per frame that brings)
    /// and adds or removes the microphone.
    func configureVideoMode(frameRate: Int?, recordsAudio: Bool) async {
        _ = try? await onSessionQueue {
            self.targetFrameRate = frameRate
            if let device = self.deviceInput?.device, (try? device.lockForConfiguration()) != nil {
                Self.apply(frameRate: frameRate, to: device)
                device.unlockForConfiguration()
            }
            self.setAudioEnabled(recordsAudio)
        }
    }

    /// Writer settings matching the microphone output, or `nil` without audio.
    func recommendedAudioSettings() async -> [String: Any]? {
        let settings = try? await onSessionQueue { () -> UncheckedBox<[String: Any]?> in
            guard self.audioInput != nil else { return UncheckedBox(value: nil) }
            return UncheckedBox(value: self.audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov))
        }
        return settings?.value
    }

    private func setAudioEnabled(_ enabled: Bool) {
        guard enabled != (audioInput != nil) else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        if enabled {
            guard let mic = AVCaptureDevice.default(for: .audio),
                  let input = try? AVCaptureDeviceInput(device: mic),
                  session.canAddInput(input)
            else { return }
            session.addInput(input)
            audioInput = input
            if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
                session.addOutput(audioOutput)
            }
        } else {
            if let audioInput { session.removeInput(audioInput) }
            audioInput = nil
            session.removeOutput(audioOutput)
        }
    }

    /// Must be called with the device locked for configuration.
    private static func apply(frameRate: Int?, to device: AVCaptureDevice) {
        guard let frameRate else {
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
            return
        }
        let fps = Float64(frameRate)
        guard device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= fps && fps <= $0.maxFrameRate })
        else { return }
        let duration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
        device.activeVideoMinFrameDuration = duration
        device.activeVideoMaxFrameDuration = duration
    }

    /// Rotation for a recording started now, relative to the upright preview frames.
    var previewRotation: CGFloat { previewRotationAngle }

    // MARK: - Controls

    func setZoom(_ factor: CGFloat, animated: Bool) {
        sessionQueue.async {
            guard let device = self.deviceInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            let clamped = min(max(factor, device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
            if animated {
                device.ramp(toVideoZoomFactor: clamped, withRate: 12)
            } else {
                device.videoZoomFactor = clamped
            }
            device.unlockForConfiguration()
        }
    }

    /// Focus and meter at a point in device coordinates ((0,0) top-left of the
    /// landscape sensor image).
    func focus(at devicePoint: CGPoint) {
        sessionQueue.async {
            guard let device = self.deviceInput?.device, (try? device.lockForConfiguration()) != nil else { return }
            if device.isFocusPointOfInterestSupported, device.isFocusModeSupported(.autoFocus) {
                device.focusPointOfInterest = devicePoint
                device.focusMode = .autoFocus
            }
            if device.isExposurePointOfInterestSupported, device.isExposureModeSupported(.autoExpose) {
                device.exposurePointOfInterest = devicePoint
                device.exposureMode = .autoExpose
            }
            device.isSubjectAreaChangeMonitoringEnabled = true
            device.unlockForConfiguration()
        }
    }

    // MARK: - Capture

    /// - Parameter rotationAngle: the device's horizon-level capture angle, written
    ///   to the photo's orientation metadata.
    func capturePhoto(flash: AVCaptureDevice.FlashMode, rotationAngle: CGFloat?) async throws -> CapturedPhoto {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                let format: [String: Any]? = self.photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_32BGRA)
                    ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                    : nil
                let settings = AVCapturePhotoSettings(format: format)
                settings.maxPhotoDimensions = self.photoOutput.maxPhotoDimensions
                settings.photoQualityPrioritization = .balanced
                if self.photoOutput.supportedFlashModes.contains(flash) { settings.flashMode = flash }

                if let connection = self.photoOutput.connection(with: .video) {
                    if let angle = rotationAngle, connection.isVideoRotationAngleSupported(angle) {
                        connection.videoRotationAngle = angle
                    }
                    if connection.isVideoMirroringSupported {
                        connection.automaticallyAdjustsVideoMirroring = false
                        connection.isVideoMirrored = self.deviceInput?.device.position == .front
                    }
                }

                let id = settings.uniqueID
                // The delegate is retained until the capture finishes, then released here.
                let delegate = PhotoCaptureDelegate(continuation: continuation) {
                    self.lock.withLock { _ = self.inFlightCaptures.removeValue(forKey: id) }
                }
                self.lock.withLock { self.inFlightCaptures[id] = delegate }
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    private func onSessionQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            sessionQueue.async {
                continuation.resume(with: Result { try work() })
            }
        }
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOutput {
            onAudio?(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }
}

/// Carries a non-Sendable value across the session queue boundary.
nonisolated struct UncheckedBox<Value>: @unchecked Sendable {
    let value: Value
}

/// Holds the continuation for one in-flight photo capture.
nonisolated private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let continuation: CheckedContinuation<CapturedPhoto, Error>
    private let onFinish: () -> Void
    private var result: Result<CapturedPhoto, Error> = .failure(CameraError.noPhotoData)

    init(continuation: CheckedContinuation<CapturedPhoto, Error>, onFinish: @escaping () -> Void) {
        self.continuation = continuation
        self.onFinish = onFinish
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            result = .failure(error)
        } else if let pixelBuffer = photo.pixelBuffer {
            result = .success(CapturedPhoto(pixelBuffer: pixelBuffer, metadata: photo.metadata))
        } else if let cgImage = photo.cgImageRepresentation(), let pixelBuffer = PixelBufferFactory.make(from: cgImage) {
            // Fallback when BGRA isn't offered: decode the processed photo.
            result = .success(CapturedPhoto(pixelBuffer: pixelBuffer, metadata: photo.metadata))
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error, case .failure = result { result = .failure(error) }
        continuation.resume(with: result)
        onFinish()
    }
}
