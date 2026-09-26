//
//  FilmThumbnail.swift
//  Film Camera
//

import SwiftUI

/// A film's sample image — local when downloaded or bundled, remote otherwise.
struct FilmThumbnail: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.2))) { phase in
            switch phase {
            case .success(let image):
                image.resizable().scaledToFill()
            case .failure:
                placeholder(systemImage: "film")
            default:
                placeholder(systemImage: nil)
            }
        }
    }

    private func placeholder(systemImage: String?) -> some View {
        Rectangle()
            .fill(.filmSurfaceContainerHigh)
            .overlay {
                if let systemImage {
                    Image(systemName: systemImage).foregroundStyle(.filmOnSurfaceVariant)
                }
            }
    }
}

/// Shown for the "no film" option.
struct NoFilmThumbnail: View {
    var body: some View {
        Rectangle()
            .fill(.filmSurfaceContainerHighest)
            .overlay {
                Image(systemName: "circle.slash")
                    .font(.title3)
                    .foregroundStyle(.filmOnSurfaceVariant)
            }
    }
}
