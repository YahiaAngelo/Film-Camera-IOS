//
//  Film_CameraTests.swift
//  Film CameraTests
//

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
