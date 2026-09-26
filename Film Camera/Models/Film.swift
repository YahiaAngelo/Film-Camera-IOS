//
//  Film.swift
//  Film Camera
//

import Foundation

/// A film emulation LUT from the Film-Luts catalog (`film_luts.json`).
nonisolated struct Film: Codable, Identifiable, Hashable, Sendable {
    let name: String
    /// Repository-relative path to the `.cube` file, e.g. `luts/bw/kodak_tri-x_400.cube`.
    let lutFile: String
    let category: String
    /// Repository-relative path to the preview thumbnail.
    let thumbnail: String

    var id: String { lutFile }

    enum CodingKeys: String, CodingKey {
        case name
        case lutFile = "lut_file"
        case category
        case thumbnail
    }

    /// Base name of the LUT file without extension, e.g. `kodak_tri-x_400`.
    var fileStem: String {
        (lutFile as NSString).lastPathComponent.replacingOccurrences(of: ".cube", with: "")
    }

    var displayName: String { Film.prettify(name) }
    var displayCategory: String { Film.prettyCategory(category) }

    static func prettyCategory(_ category: String) -> String {
        switch category {
        case "Bw": "Black & White"
        case "Colorslide": "Color Slide"
        case "Fujixtransiii": "Fuji X-Trans III"
        case "Print": "Cinema Print"
        default: category
        }
    }

    private static let nameFixes: [(String, String)] = [
        ("Xtrans Iii", "X-Trans III"),
        ("Hp 5", "HP5"),
        ("Hps", "HPS"),
        ("Fp 4", "FP4"),
        ("Xp 2", "XP2"),
        ("Apx", "APX"),
        ("Bw", "B&W"),
        ("Cn", "CN"),
        ("Hie Hs", "HIE HS"),
        (" Nc", " NC"),
        (" Vc", " VC"),
        (" Uc", " UC"),
        (" Hc", " HC"),
        (" Hg", " HG"),
        ("Ir ", "IR "),
        ("Px-", "PX-"),
        ("Uv", "UV"),
        ("T-Max", "T-MAX"),
        ("E-100 Gx", "E100 GX"),
        ("Vs", "VS"),
        ("Xpro", "X-Pro"),
        ("X-Pro Slide", "X-Pro Slide"),
        ("Constlclip", "Const. Clip"),
        ("Constlmap", "Const. Map"),
        ("Cuspclip", "Cusp Clip"),
    ]

    static func prettify(_ name: String) -> String {
        nameFixes.reduce(name) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }
}

nonisolated struct FilmCatalog: Codable, Sendable {
    let filmLUTs: [Film]
}
