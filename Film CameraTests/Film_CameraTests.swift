//
//  Film_CameraTests.swift
//  Film CameraTests
//

import AVFoundation
import CoreGraphics
import Foundation
import Testing
@testable import Film_Camera

struct CubeLUTTests {
    @Test func parsesHeaderCommentsAndData() throws {
        let text = """
        # Created by: G'MIC
        TITLE "test"

        LUT_3D_SIZE 2
        DOMAIN_MIN 0.0 0.0 0.0
        DOMAIN_MAX 1.0 1.0 1.0
        0 0 0
        1 0 0
        0 1 0
        1 1 0
        0 0 1
        1 0 1
        0 1 1
        1 1 1
        """
        let lut = try CubeLUT(parsing: text)
        #expect(lut.size == 2)
        #expect(lut.values == CubeLUT.identity.values)
        #expect(lut.domainMax == SIMD3(1, 1, 1))
    }

    @Test func rejectsTruncatedData() {
        #expect(throws: CubeLUT.ParseError.self) {
            try CubeLUT(parsing: "LUT_3D_SIZE 2\n0 0 0\n1 1 1\n")
        }
    }

    @Test func rejects1DLUTs() {
        #expect(throws: CubeLUT.ParseError.self) {
            try CubeLUT(parsing: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        }
    }

    @Test func parsesEveryBundledFilm() throws {
        for id in FilmLibrary.bundledIDs {
            let stem = ((id as NSString).lastPathComponent as NSString).deletingPathExtension
            let url = try #require(Bundle.main.url(forResource: stem, withExtension: "cube"), "Missing bundled \(stem)")
            let lut = try CubeLUT(contentsOf: url)
            #expect(lut.values.count == lut.size * lut.size * lut.size * 3)
        }
    }
}

struct FilmCatalogTests {
    @Test func bundledCatalogDecodesAndContainsBundledFilms() throws {
        let url = try #require(Bundle.main.url(forResource: "film_luts", withExtension: "json"))
        let catalog = try JSONDecoder().decode(FilmCatalog.self, from: Data(contentsOf: url))
        #expect(catalog.filmLUTs.count > 200)
        let ids = Set(catalog.filmLUTs.map(\.id))
        for id in FilmLibrary.bundledIDs {
            #expect(ids.contains(id))
        }
    }

    @Test func prettifiesNames() {
        #expect(Film.prettify("Fuji Xtrans Iii Classic Chrome") == "Fuji X-Trans III Classic Chrome")
        #expect(Film.prettify("Ilford Hp 5 Plus 400") == "Ilford HP5 Plus 400")
        #expect(Film.prettyCategory("Bw") == "Black & White")
    }
}

struct SensorMappingTests {
    private func isClose(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1e-9 && abs(a.y - b.y) < 1e-9
    }

    @Test func backCameraPortrait() {
        // 90° rotation: frame top-left maps to sensor bottom-left.
        #expect(CameraModel.sensorPoint(u: 0, v: 0, rotation: 90, mirrored: false) == CGPoint(x: 0, y: 1))
        #expect(CameraModel.sensorPoint(u: 0.5, v: 0.5, rotation: 90, mirrored: false) == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func mirroredFrontCameraAt90MatchesPreviewLayerConvention() {
        #expect(isClose(CameraModel.sensorPoint(u: 0.2, v: 0.7, rotation: 90, mirrored: true), CGPoint(x: 0.7, y: 0.2)))
    }

    @Test func unrotatedSensorIsIdentityWhenNotMirrored() {
        #expect(CameraModel.sensorPoint(u: 0.2, v: 0.7, rotation: 0, mirrored: false) == CGPoint(x: 0.2, y: 0.7))
    }
}

struct Super8Tests {
    @Test func frameEffectsAreDeterministic() {
        let a = FilmAdjustments.default
        #expect(Super8FrameEffects.make(frame: 42, clipFrame: nil, adjustments: a)
                == Super8FrameEffects.make(frame: 42, clipFrame: nil, adjustments: a))
        #expect(Super8FrameEffects.make(frame: 42, clipFrame: nil, adjustments: a)
                != Super8FrameEffects.make(frame: 43, clipFrame: nil, adjustments: a))
    }

    @Test func startFlashFadesOutOverFirstFrames() {
        let a = FilmAdjustments.default
        let first = Super8FrameEffects.make(frame: 100, clipFrame: 0, adjustments: a).flash
        let later = Super8FrameEffects.make(frame: 105, clipFrame: 5, adjustments: a).flash
        let done = Super8FrameEffects.make(frame: 110, clipFrame: Super8FrameEffects.flashFrames, adjustments: a).flash
        #expect(first > later && later > 0)
        #expect(done == 0)
        #expect(Super8FrameEffects.make(frame: 100, clipFrame: nil, adjustments: a).flash == 0)
    }

    @Test func effectsTurnOffWithTheirSliders() {
        var a = FilmAdjustments.default
        a.gateWeave = 0
        a.flicker = 0
        a.dust = 0
        for frame in UInt32(0)..<200 {
            let e = Super8FrameEffects.make(frame: frame, clipFrame: nil, adjustments: a)
            #expect(e.weaveX == 0 && e.weaveY == 0 && e.flicker == 1 && e.scratchStrength == 0)
        }
    }

    @Test func oldSavedAdjustmentsStillDecode() throws {
        // Saved before the Super 8 adjustments existed.
        let json = #"{"lutIntensity":0.8,"exposure":0.5,"contrast":0,"highlights":0,"shadows":0,"saturation":0,"temperature":0,"tint":0,"fade":0,"grain":0.6,"grainSize":0.35,"glow":0,"halation":0,"vignette":0.2}"#
        let a = try JSONDecoder().decode(FilmAdjustments.self, from: Data(json.utf8))
        #expect(a.exposure == 0.5 && a.grain == 0.6)
        #expect(a.dust == FilmAdjustments.default.dust)
    }

    /// Records a short clip through the real renderer and writer, then checks the file.
    @Test func recorderWritesPlayableClip() async throws {
        let renderer = try #require(FilmRenderer())
        renderer.setSuper8(true)
        let recorder = Super8Recorder(renderer: renderer)
        let url = FileManager.default.temporaryDirectory.appending(path: "super8-test.mov")
        try recorder.start(url: url, size: CGSize(width: 480, height: 640), transform: .identity, frameRate: 18, audioSettings: nil)

        let image = try #require(CGContext(data: nil, width: 540, height: 720, bitsPerComponent: 8, bytesPerRow: 0,
                                           space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                           bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
        let frame = try #require(PixelBufferFactory.make(from: image))
        let frames = 36
        for i in 0..<frames {
            renderer.enqueue(frame: frame)
            recorder.appendVideo(frame, time: CMTime(value: CMTimeValue(i), timescale: 18))
            // Feed at roughly camera pace; like live capture, the recorder drops
            // frames the encoder isn't ready for.
            try await Task.sleep(for: .milliseconds(40))
        }
        let output = try await recorder.finish()

        let asset = AVURLAsset(url: output)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let size = try await track.load(.naturalSize)
        let duration = try await asset.load(.duration)
        #expect(size == CGSize(width: 480, height: 640))
        #expect(abs(duration.seconds - Double(frames) / 18) < 0.1)
        try? FileManager.default.removeItem(at: output)
    }
}
