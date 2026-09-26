//
//  CubeLUT.swift
//  Film Camera
//

import Foundation

/// A parsed Adobe/Resolve `.cube` 3D LUT. Values are RGB triplets with red
/// varying fastest, then green, then blue — the same layout as a 3D texture
/// with x = red, y = green, z = blue.
nonisolated struct CubeLUT: Sendable {
    enum ParseError: Error, LocalizedError {
        case missingSize
        case unsupported1D
        case invalidLine(String)
        case wrongValueCount(expected: Int, actual: Int)

        var errorDescription: String? {
            switch self {
            case .missingSize: "The LUT file has no LUT_3D_SIZE."
            case .unsupported1D: "1D LUTs are not supported."
            case .invalidLine(let line): "Invalid LUT line: \(line)"
            case .wrongValueCount(let expected, let actual): "Expected \(expected) LUT entries, found \(actual)."
            }
        }
    }

    let size: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    /// Flat RGB values, `size³ * 3` floats.
    let values: [Float]

    init(size: Int, values: [Float], domainMin: SIMD3<Float> = .zero, domainMax: SIMD3<Float> = .one) {
        self.size = size
        self.values = values
        self.domainMin = domainMin
        self.domainMax = domainMax
    }

    init(contentsOf url: URL) throws {
        try self.init(parsing: String(contentsOf: url, encoding: .utf8))
    }

    init(parsing text: String) throws {
        var size = 0
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var values: [Float] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard let first = line.first, first != "#" else { continue }

            if first.isLetter {
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                switch parts.first {
                case "LUT_3D_SIZE":
                    guard parts.count > 1, let value = Int(parts[1]) else { throw ParseError.invalidLine(line) }
                    size = value
                    values.reserveCapacity(size * size * size * 3)
                case "LUT_1D_SIZE":
                    throw ParseError.unsupported1D
                case "DOMAIN_MIN":
                    domainMin = try Self.vector(parts.dropFirst(), line: line)
                case "DOMAIN_MAX":
                    domainMax = try Self.vector(parts.dropFirst(), line: line)
                default:
                    continue // TITLE and other keywords
                }
                continue
            }

            var count = 0
            for component in line.split(separator: " ", omittingEmptySubsequences: true) {
                guard let value = Float(component) else { throw ParseError.invalidLine(line) }
                values.append(value)
                count += 1
            }
            guard count == 3 else { throw ParseError.invalidLine(line) }
        }

        guard size > 1 else { throw ParseError.missingSize }
        let expected = size * size * size
        guard values.count == expected * 3 else {
            throw ParseError.wrongValueCount(expected: expected, actual: values.count / 3)
        }
        self.init(size: size, values: values, domainMin: domainMin, domainMax: domainMax)
    }

    private static func vector(_ parts: ArraySlice<Substring>, line: String) throws -> SIMD3<Float> {
        let floats = parts.compactMap { Float($0) }
        guard floats.count == 3 else { throw ParseError.invalidLine(line) }
        return SIMD3(floats[0], floats[1], floats[2])
    }

    /// A 2×2×2 LUT that maps every color to itself.
    static let identity: CubeLUT = {
        var values: [Float] = []
        for b in 0..<2 {
            for g in 0..<2 {
                for r in 0..<2 {
                    values += [Float(r), Float(g), Float(b)]
                }
            }
        }
        return CubeLUT(size: 2, values: values)
    }()
}
