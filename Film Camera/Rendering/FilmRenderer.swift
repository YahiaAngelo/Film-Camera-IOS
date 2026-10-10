//
//  FilmRenderer.swift
//  Film Camera
//

import CoreGraphics
import CoreVideo
import Foundation
import Metal
import MetalKit
import MetalPerformanceShaders
import QuartzCore

/// Mirrors `FilmUniforms` in FilmShaders.metal. Only 32-bit floats, so the
/// layout is identical on both sides.
nonisolated struct FilmUniforms {
    var exposure: Float = 0
    var contrast: Float = 0
    var highlights: Float = 0
    var shadows: Float = 0
    var saturation: Float = 0
    var temperature: Float = 0
    var tint: Float = 0
    var fade: Float = 0
    var lutIntensity: Float = 0
    var lutSize: Float = 2
    var lutDomainMinR: Float = 0, lutDomainMinG: Float = 0, lutDomainMinB: Float = 0
    var lutDomainMaxR: Float = 1, lutDomainMaxG: Float = 1, lutDomainMaxB: Float = 1
    var grain: Float = 0
    var grainScale: Float = 1
    var glow: Float = 0
    var halation: Float = 0
    var vignette: Float = 0
    var grainSeed: Float = 0
    var aspect: Float = 1
    var uvScaleX: Float = 1, uvScaleY: Float = 1
    var uvOffsetX: Float = 0, uvOffsetY: Float = 0
    // Super 8 (all zero in photo mode)
    var super8: Float = 0
    var weaveX: Float = 0, weaveY: Float = 0
    var flicker: Float = 1
    var dust: Float = 0
    var scratchX: Float = 0, scratchStrength: Float = 0
    var flash: Float = 0
    var softness: Float = 0
}

/// Per-film-frame Super 8 artifacts, derived deterministically from the frame
/// number so the preview and the recording show exactly the same thing.
nonisolated struct Super8FrameEffects: Equatable {
    var weaveX: Float = 0
    var weaveY: Float = 0
    var flicker: Float = 1
    var scratchX: Float = 0
    var scratchStrength: Float = 0
    var flash: Float = 0

    /// Frames over which the cartridge-start light flash fades out.
    static let flashFrames = 10

    /// - Parameters:
    ///   - frame: running film frame number.
    ///   - clipFrame: frame number within the current recording, or `nil` when not recording.
    static func make(frame: UInt32, clipFrame: Int?, adjustments a: FilmAdjustments) -> Super8FrameEffects {
        var e = Super8FrameEffects()
        let f = Float(frame)
        // Gate weave: jittery claw pull-down, mostly vertical, plus a slow drift.
        let weave = a.gateWeave * 2
        e.weaveX = ((random(frame, 1) - 0.5) * 0.0018 + sin(f * 0.23 + 1) * 0.0008) * weave
        e.weaveY = ((random(frame, 2) - 0.5) * 0.0045 + sin(f * 0.37) * 0.0012) * weave
        // Exposure flicker.
        e.flicker = 1 + (random(frame, 3) - 0.5) * 0.14 * a.flicker
        // A scratch appears now and then and lingers for about half a second.
        let event = frame / 10
        if random(event, 4) < 0.3 * a.dust {
            e.scratchX = 0.08 + random(event, 5) * 0.84 + (random(frame, 6) - 0.5) * 0.002
            e.scratchStrength = (0.25 + random(event, 7) * 0.35) * min(1, a.dust * 1.5)
        }
        if let clipFrame, clipFrame < flashFrames {
            e.flash = pow(1 - Float(clipFrame) / Float(flashFrames), 1.5) * 0.9
        }
        return e
    }

    /// Deterministic 0..<1 value for a frame and a channel (SplitMix64).
    static func random(_ frame: UInt32, _ channel: UInt64) -> Float {
        var z = UInt64(frame) &* 0x9E37_79B9_7F4A_7C15 &+ channel &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Float(z >> 40) / Float(1 << 24)
    }
}

/// Renders camera frames through the film pipeline. The live preview and the
/// full-resolution photo go through the exact same shaders, so what you see is
/// what you get.
///
/// Thread-safety: film/adjustment state and the latest frame are guarded by a
/// lock. Preview drawing happens on the main thread; photo rendering can run on
/// any thread.
nonisolated final class FilmRenderer: @unchecked Sendable {
    let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let gradePipeline: MTLComputePipelineState
    private let brightPipeline: MTLComputePipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let textureCache: CVMetalTextureCache
    private let identityLUT: LUTTexture
    private let blackTexture: MTLTexture
    private let supportsMPS: Bool

    private let lock = NSLock()
    private var lut: LUTTexture?
    private var adjustments = FilmAdjustments.default
    private var latestFrame: CVPixelBuffer?
    private var blurCache: [Int: MPSImageGaussianBlur] = [:]
    private var super8Enabled = false
    /// Counts camera frames in Super 8 mode; each one is a "film frame".
    private var filmFrame: UInt32 = 0
    private var clipStartFrame: UInt32?

    // Preview-only intermediates, touched on the main thread.
    private var previewTargets: Intermediates?
    private var frameIndex: UInt32 = 0
    // Video-only intermediates, touched only by the recorder's serial queue.
    private var videoTargets: Intermediates?

    static let previewPixelFormat: MTLPixelFormat = .bgra8Unorm

    struct LUTTexture {
        let texture: MTLTexture
        let size: Int
        let domainMin: SIMD3<Float>
        let domainMax: SIMD3<Float>
    }

    private struct Intermediates {
        let graded: MTLTexture
        let brightA: MTLTexture
        let brightB: MTLTexture
        var width: Int { graded.width }
        var height: Int { graded.height }
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let grade = library.makeFunction(name: "filmGrade"),
              let bright = library.makeFunction(name: "filmBright"),
              let vertex = library.makeFunction(name: "filmVertex"),
              let fragment = library.makeFunction(name: "filmComposite")
        else { return nil }

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        guard let cache else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = Self.previewPixelFormat

        do {
            gradePipeline = try device.makeComputePipelineState(function: grade)
            brightPipeline = try device.makeComputePipelineState(function: bright)
            compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            print("FilmRenderer: pipeline creation failed: \(error)")
            return nil
        }

        self.device = device
        self.commandQueue = queue
        self.textureCache = cache
        self.supportsMPS = MPSSupportsMTLDevice(device)

        guard let identity = Self.makeLUTTexture(CubeLUT.identity, device: device),
              let black = Self.makeTexture(device: device, width: 1, height: 1, format: .rgba8Unorm, usage: .shaderRead, storage: .shared)
        else { return nil }
        black.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](arrayLiteral: 0, 0, 0, 255), bytesPerRow: 4)
        identityLUT = identity
        blackTexture = black
    }

    // MARK: - State

    func setLUT(_ cube: CubeLUT?) {
        let texture = cube.flatMap { Self.makeLUTTexture($0, device: device) }
        lock.withLock { lut = texture }
    }

    func setAdjustments(_ value: FilmAdjustments) {
        lock.withLock { adjustments = value }
    }

    func enqueue(frame: CVPixelBuffer) {
        lock.withLock {
            latestFrame = frame
            if super8Enabled { filmFrame &+= 1 }
        }
    }

    func setSuper8(_ enabled: Bool) {
        lock.withLock { super8Enabled = enabled }
    }

    /// Marks the current film frame as the start of a recording (for the start flash).
    func beginClip() {
        lock.withLock { clipStartFrame = filmFrame &+ 1 }
    }

    func endClip() {
        lock.withLock { clipStartFrame = nil }
    }

    /// Size of the most recent preview frame, used to map taps to the sensor.
    var latestFrameSize: CGSize? {
        lock.withLock {
            latestFrame.map { CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0)) }
        }
    }

    private func snapshot() -> (LUTTexture, Bool, FilmAdjustments) {
        lock.withLock { (lut ?? identityLUT, lut != nil, adjustments) }
    }

    // MARK: - Preview

    /// Draws the latest camera frame into the view, aspect-filling it.
    @MainActor func draw(in view: MTKView) {
        guard let frame = lock.withLock({ latestFrame }),
              let source = makeTexture(from: frame),
              let drawable = view.currentDrawable,
              let pass = view.currentRenderPassDescriptor,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return }

        let width = source.width
        let height = source.height
        if previewTargets?.width != width || previewTargets?.height != height {
            previewTargets = makeIntermediates(width: width, height: height, format: .rgba16Float)
        }
        guard let targets = previewTargets else { return }

        // Aspect-fill crop of the image into the drawable.
        let drawableSize = view.drawableSize
        let scale = max(drawableSize.width / Double(width), drawableSize.height / Double(height))
        let visibleU = drawableSize.width / (Double(width) * scale)
        let visibleV = drawableSize.height / (Double(height) * scale)

        var uniforms = makeUniforms(imageWidth: width, imageHeight: height)
        if uniforms.super8 == 0 {
            // New grain every drawn frame, so it dances like projected film.
            // (In Super 8 mode grain follows the film frame instead.)
            frameIndex &+= 1
            uniforms.grainSeed = Float(frameIndex % 65_536)
        }
        uniforms.uvScaleX = Float(visibleU)
        uniforms.uvScaleY = Float(visibleV)
        uniforms.uvOffsetX = Float((1 - visibleU) / 2)
        uniforms.uvOffsetY = Float((1 - visibleV) / 2)

        let bloom = encodeGradeAndBloom(source: source, targets: targets, uniforms: &uniforms, commandBuffer: commandBuffer)
        encodeComposite(graded: targets.graded, bloom: bloom, pass: pass, uniforms: &uniforms, commandBuffer: commandBuffer)

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    // MARK: - Photo

    /// Renders a full-resolution BGRA pixel buffer through the film pipeline.
    func renderPhoto(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        guard let source = makeTexture(from: pixelBuffer),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return nil }

        let width = source.width
        let height = source.height
        guard let targets = makeIntermediates(width: width, height: height, format: .rgba8Unorm),
              let output = Self.makeTexture(device: device, width: width, height: height,
                                            format: Self.previewPixelFormat, usage: [.renderTarget, .shaderRead],
                                            storage: .shared)
        else { return nil }

        var uniforms = makeUniforms(imageWidth: width, imageHeight: height, super8: false)
        uniforms.grainSeed = Float(UInt32.random(in: 0..<65_536))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        let bloom = encodeGradeAndBloom(source: source, targets: targets, uniforms: &uniforms, commandBuffer: commandBuffer)
        encodeComposite(graded: targets.graded, bloom: bloom, pass: pass, uniforms: &uniforms, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { return nil }

        return Self.makeCGImage(from: output)
    }

    // MARK: - Video

    /// Renders one Super 8 frame into `output` (a BGRA buffer from the writer's
    /// pool), scaling to its size. Call from a single serial queue.
    func renderVideoFrame(_ source: CVPixelBuffer, into output: CVPixelBuffer) -> Bool {
        guard let sourceTexture = makeTexture(from: source),
              let outputTexture = makeTexture(from: output),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { return false }

        let width = sourceTexture.width
        let height = sourceTexture.height
        if videoTargets?.width != width || videoTargets?.height != height {
            videoTargets = makeIntermediates(width: width, height: height, format: .rgba16Float)
        }
        guard let targets = videoTargets else { return false }

        var uniforms = makeUniforms(imageWidth: width, imageHeight: height)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = outputTexture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        let bloom = encodeGradeAndBloom(source: sourceTexture, targets: targets, uniforms: &uniforms, commandBuffer: commandBuffer)
        encodeComposite(graded: targets.graded, bloom: bloom, pass: pass, uniforms: &uniforms, commandBuffer: commandBuffer)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        return commandBuffer.status == .completed
    }

    // MARK: - Encoding

    /// - Parameter super8: pass `false` to force the photo look (e.g. for stills).
    private func makeUniforms(imageWidth: Int, imageHeight: Int, super8: Bool? = nil) -> FilmUniforms {
        let (lut, hasFilm, a) = snapshot()
        let (super8Enabled, filmFrame, clipStart) = lock.withLock { (self.super8Enabled, self.filmFrame, clipStartFrame) }
        var u = FilmUniforms()
        u.exposure = a.exposure
        u.contrast = a.contrast
        u.highlights = a.highlights
        u.shadows = a.shadows
        u.saturation = a.saturation
        u.temperature = a.temperature
        u.tint = a.tint
        u.fade = a.fade
        u.lutIntensity = hasFilm ? a.lutIntensity : 0
        u.lutSize = Float(lut.size)
        u.lutDomainMinR = lut.domainMin.x; u.lutDomainMinG = lut.domainMin.y; u.lutDomainMinB = lut.domainMin.z
        u.lutDomainMaxR = lut.domainMax.x; u.lutDomainMaxG = lut.domainMax.y; u.lutDomainMaxB = lut.domainMax.z
        u.grain = a.grain
        // Grain cells per image height: finer at 0, coarser at 1. Relative to the
        // image, so the preview matches the saved photo.
        u.grainScale = 1500 / (1 + a.grainSize * 3)
        u.glow = a.glow
        u.halation = a.halation
        u.vignette = a.vignette
        // Keeps grain cells square regardless of the image's aspect ratio.
        u.aspect = Float(imageWidth) / Float(imageHeight)

        if super8 ?? super8Enabled {
            let clipFrame = clipStart.map { Int(Int32(bitPattern: filmFrame &- $0)) }.flatMap { $0 >= 0 ? $0 : nil }
            let e = Super8FrameEffects.make(frame: filmFrame, clipFrame: clipFrame, adjustments: a)
            u.super8 = 1
            u.weaveX = e.weaveX
            u.weaveY = e.weaveY
            u.flicker = e.flicker
            u.scratchX = e.scratchX
            u.scratchStrength = e.scratchStrength
            u.flash = e.flash
            u.dust = a.dust
            u.softness = 0.0009
            // A Super 8 frame is tiny, so grain is large relative to the picture.
            u.grain = max(a.grain, 0.45) * 1.25
            u.grainScale = 620 / (1 + a.grainSize * 1.5)
            u.vignette = max(a.vignette, 0.5)
            // Grain and dust change once per film frame, not per screen refresh.
            u.grainSeed = Float(filmFrame % 65_536)
        }
        return u
    }

    /// Grades `source` into `targets.graded` and returns the blurred bloom texture.
    private func encodeGradeAndBloom(source: MTLTexture, targets: Intermediates,
                                     uniforms: inout FilmUniforms,
                                     commandBuffer: MTLCommandBuffer) -> MTLTexture {
        let (lut, _, _) = snapshot()

        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            encoder.setComputePipelineState(gradePipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(lut.texture, index: 1)
            encoder.setTexture(targets.graded, index: 2)
            encoder.setBytes(&uniforms, length: MemoryLayout<FilmUniforms>.stride, index: 0)
            dispatch(encoder, pipeline: gradePipeline, width: targets.graded.width, height: targets.graded.height)

            guard uniforms.glow > 0.001 || uniforms.halation > 0.001 else {
                encoder.endEncoding()
                return blackTexture
            }

            encoder.setComputePipelineState(brightPipeline)
            encoder.setTexture(targets.graded, index: 0)
            encoder.setTexture(targets.brightA, index: 1)
            dispatch(encoder, pipeline: brightPipeline, width: targets.brightA.width, height: targets.brightA.height)
            encoder.endEncoding()
        }

        guard supportsMPS else { return targets.brightA }
        let blur = blurKernel(sigma: Float(max(targets.brightA.width, targets.brightA.height)) * 0.03)
        blur.encode(commandBuffer: commandBuffer, sourceTexture: targets.brightA, destinationTexture: targets.brightB)
        return targets.brightB
    }

    private func encodeComposite(graded: MTLTexture, bloom: MTLTexture, pass: MTLRenderPassDescriptor,
                                 uniforms: inout FilmUniforms, commandBuffer: MTLCommandBuffer) {
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setFragmentTexture(graded, index: 0)
        encoder.setFragmentTexture(bloom, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<FilmUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, width: Int, height: Int) {
        let w = pipeline.threadExecutionWidth
        let h = max(1, pipeline.maxTotalThreadsPerThreadgroup / w)
        let threadsPerGroup = MTLSize(width: w, height: h, depth: 1)
        let groups = MTLSize(width: (width + w - 1) / w, height: (height + h - 1) / h, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }

    private func blurKernel(sigma: Float) -> MPSImageGaussianBlur {
        let key = Int(sigma.rounded())
        return lock.withLock {
            if let cached = blurCache[key] { return cached }
            let kernel = MPSImageGaussianBlur(device: device, sigma: Float(max(key, 1)))
            kernel.edgeMode = .clamp
            blurCache[key] = kernel
            return kernel
        }
    }

    // MARK: - Textures

    private func makeTexture(from pixelBuffer: CVPixelBuffer) -> MTLTexture? {
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil, .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer), 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }

    private func makeIntermediates(width: Int, height: Int, format: MTLPixelFormat) -> Intermediates? {
        let bw = max(1, width / 4)
        let bh = max(1, height / 4)
        guard let graded = Self.makeTexture(device: device, width: width, height: height, format: format, usage: [.shaderRead, .shaderWrite]),
              let a = Self.makeTexture(device: device, width: bw, height: bh, format: .rgba16Float, usage: [.shaderRead, .shaderWrite]),
              let b = Self.makeTexture(device: device, width: bw, height: bh, format: .rgba16Float, usage: [.shaderRead, .shaderWrite])
        else { return nil }
        return Intermediates(graded: graded, brightA: a, brightB: b)
    }

    private static func makeTexture(device: MTLDevice, width: Int, height: Int, format: MTLPixelFormat,
                                    usage: MTLTextureUsage, storage: MTLStorageMode = .private) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.usage = usage
        descriptor.storageMode = storage
        return device.makeTexture(descriptor: descriptor)
    }

    static func makeLUTTexture(_ cube: CubeLUT, device: MTLDevice) -> LUTTexture? {
        let n = cube.size
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = n
        descriptor.height = n
        descriptor.depth = n
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        let count = n * n * n
        var rgba = [Float16](repeating: 1, count: count * 4)
        cube.values.withUnsafeBufferPointer { src in
            for i in 0..<count {
                rgba[i * 4] = Float16(src[i * 3])
                rgba[i * 4 + 1] = Float16(src[i * 3 + 1])
                rgba[i * 4 + 2] = Float16(src[i * 3 + 2])
            }
        }
        let pixelSize = 4 * MemoryLayout<Float16>.size
        rgba.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                            withBytes: bytes.baseAddress!, bytesPerRow: n * pixelSize, bytesPerImage: n * n * pixelSize)
        }
        return LUTTexture(texture: texture, size: n, domainMin: cube.domainMin, domainMax: cube.domainMax)
    }

    private static func makeCGImage(from texture: MTLTexture) -> CGImage? {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { bytes in
            texture.getBytes(bytes.baseAddress!, bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: false, intent: .defaultIntent)
    }
}
