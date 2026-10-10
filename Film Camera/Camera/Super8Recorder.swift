//
//  Super8Recorder.swift
//  Film Camera
//

@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Writes Super 8 clips: every camera frame is rendered through the film
/// pipeline (the same frame the preview shows) and appended to an
/// `AVAssetWriter`, along with microphone audio.
///
/// Video and audio arrive on different queues; all writer access is serialized
/// by a lock so a clip can't be finished while a frame is being appended.
nonisolated final class Super8Recorder: @unchecked Sendable {
    enum RecorderError: LocalizedError {
        case cannotCreateWriter
        case noFrames
        case writeFailed(Error?)

        var errorDescription: String? {
            switch self {
            case .cannotCreateWriter: "The video file couldn't be created."
            case .noFrames: "The clip was too short to save."
            case .writeFailed(let error): "The video couldn't be saved. \(error?.localizedDescription ?? "")"
            }
        }
    }

    /// 50 ft Super 8 cartridge: 72 frames per foot.
    static let framesPerFoot = 72
    static let cartridgeFeet = 50
    static let cartridgeFrames = framesPerFoot * cartridgeFeet

    /// Called on the capture queue after each written frame, with the frame count.
    var onFrameWritten: (@Sendable (Int) -> Void)?

    private let renderer: FilmRenderer
    private let lock = NSLock()
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var isAccepting = false
    private var sessionStarted = false
    private var framesWritten = 0

    init(renderer: FilmRenderer) {
        self.renderer = renderer
    }

    var isRecording: Bool { lock.withLock { isAccepting } }

    /// - Parameters:
    ///   - size: output size in pixels (both dimensions even).
    ///   - transform: display rotation for when the phone was held sideways.
    ///   - audioSettings: `nil` records a silent clip.
    func start(url: URL, size: CGSize, transform: CGAffineTransform, frameRate: Int, audioSettings: [String: Any]?) throws {
        try? FileManager.default.removeItem(at: url)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else { throw RecorderError.cannotCreateWriter }

        #if targetEnvironment(simulator)
        let codec = AVVideoCodecType.h264
        #else
        let codec = AVVideoCodecType.hevc
        #endif
        let width = Int(size.width)
        let height = Int(size.height)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: codec,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ],
        ])
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
        ])
        guard writer.canAdd(videoInput) else { throw RecorderError.cannotCreateWriter }
        writer.add(videoInput)

        var audioInput: AVAssetWriterInput?
        if let audioSettings {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }

        guard writer.startWriting() else { throw RecorderError.writeFailed(writer.error) }

        lock.withLock {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            sessionStarted = false
            framesWritten = 0
            isAccepting = true
        }
    }

    /// Renders and appends one camera frame. Call on the capture queue.
    func appendVideo(_ source: CVPixelBuffer, time: CMTime) {
        let written: Int? = lock.withLock {
            guard isAccepting, let writer, let videoInput, let adaptor, writer.status == .writing else { return nil }
            if !sessionStarted {
                writer.startSession(atSourceTime: time)
                sessionStarted = true
            }
            guard videoInput.isReadyForMoreMediaData, let pool = adaptor.pixelBufferPool else { return nil }
            var output: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &output)
            guard let output, renderer.renderVideoFrame(source, into: output),
                  adaptor.append(output, withPresentationTime: time)
            else { return nil }
            framesWritten += 1
            return framesWritten
        }
        if let written { onFrameWritten?(written) }
    }

    /// Appends microphone audio. Call on the audio queue.
    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        lock.withLock {
            guard isAccepting, sessionStarted, let audioInput, audioInput.isReadyForMoreMediaData else { return }
            audioInput.append(sampleBuffer)
        }
    }

    /// Stops accepting frames and finalizes the file.
    func finish() async throws -> URL {
        let (writer, inputs, hasFrames): (AVAssetWriter?, [AVAssetWriterInput], Bool) = lock.withLock {
            isAccepting = false
            defer {
                self.writer = nil
                videoInput = nil
                audioInput = nil
                adaptor = nil
            }
            return (self.writer, [videoInput, audioInput].compactMap { $0 }, sessionStarted && framesWritten > 0)
        }
        guard let writer else { throw RecorderError.noFrames }
        guard hasFrames else {
            writer.cancelWriting()
            throw RecorderError.noFrames
        }
        inputs.forEach { $0.markAsFinished() }
        await writer.finishWriting()
        guard writer.status == .completed else { throw RecorderError.writeFailed(writer.error) }
        return writer.outputURL
    }
}
