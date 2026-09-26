//
//  FilmAdjustments.swift
//  Film Camera
//

import Foundation

/// Image adjustments applied on top of the film LUT. All values are normalized
/// so the shader can consume them directly.
nonisolated struct FilmAdjustments: Codable, Equatable, Sendable {
    var lutIntensity: Float = 1
    var exposure: Float = 0      // EV, -2...2
    var contrast: Float = 0      // -1...1
    var highlights: Float = 0    // -1...1
    var shadows: Float = 0       // -1...1
    var saturation: Float = 0    // -1...1
    var temperature: Float = 0   // -1...1
    var tint: Float = 0          // -1...1
    var fade: Float = 0          // 0...1
    var grain: Float = 0.3       // 0...1
    var grainSize: Float = 0.35  // 0...1
    var glow: Float = 0          // 0...1
    var halation: Float = 0      // 0...1
    var vignette: Float = 0.2    // 0...1

    static let `default` = FilmAdjustments()
}

/// Describes one slider in the adjustments panel.
struct AdjustmentControl: Identifiable {
    enum Group: String, CaseIterable {
        case film = "Film"
        case light = "Light"
        case color = "Color"
        case effects = "Effects"
    }

    let id: String
    let title: String
    let systemImage: String
    let group: Group
    let range: ClosedRange<Float>
    let keyPath: WritableKeyPath<FilmAdjustments, Float>

    var defaultValue: Float { FilmAdjustments.default[keyPath: keyPath] }
    var isBipolar: Bool { range.lowerBound < 0 }

    func formatted(_ value: Float) -> String {
        if keyPath == \FilmAdjustments.exposure {
            return String(format: "%+.1f EV", value)
        }
        let percent = Int((value * 100).rounded())
        return isBipolar && percent > 0 ? "+\(percent)" : "\(percent)"
    }

    static let all: [AdjustmentControl] = [
        .init(id: "intensity", title: "Film Strength", systemImage: "film", group: .film, range: 0...1, keyPath: \.lutIntensity),
        .init(id: "exposure", title: "Exposure", systemImage: "plusminus.circle", group: .light, range: -2...2, keyPath: \.exposure),
        .init(id: "contrast", title: "Contrast", systemImage: "circle.lefthalf.filled", group: .light, range: -1...1, keyPath: \.contrast),
        .init(id: "highlights", title: "Highlights", systemImage: "sun.max", group: .light, range: -1...1, keyPath: \.highlights),
        .init(id: "shadows", title: "Shadows", systemImage: "moon", group: .light, range: -1...1, keyPath: \.shadows),
        .init(id: "fade", title: "Fade", systemImage: "circle.bottomhalf.filled", group: .light, range: 0...1, keyPath: \.fade),
        .init(id: "saturation", title: "Saturation", systemImage: "drop.halffull", group: .color, range: -1...1, keyPath: \.saturation),
        .init(id: "temperature", title: "Warmth", systemImage: "thermometer.medium", group: .color, range: -1...1, keyPath: \.temperature),
        .init(id: "tint", title: "Tint", systemImage: "eyedropper.halffull", group: .color, range: -1...1, keyPath: \.tint),
        .init(id: "grain", title: "Grain", systemImage: "circle.dotted", group: .effects, range: 0...1, keyPath: \.grain),
        .init(id: "grainSize", title: "Grain Size", systemImage: "circle.grid.3x3", group: .effects, range: 0...1, keyPath: \.grainSize),
        .init(id: "glow", title: "Glow", systemImage: "sparkles", group: .effects, range: 0...1, keyPath: \.glow),
        .init(id: "halation", title: "Halation", systemImage: "rays", group: .effects, range: 0...1, keyPath: \.halation),
        .init(id: "vignette", title: "Vignette", systemImage: "circle.dashed", group: .effects, range: 0...1, keyPath: \.vignette),
    ]
}
