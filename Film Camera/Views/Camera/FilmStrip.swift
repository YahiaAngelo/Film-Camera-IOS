//
//  FilmStrip.swift
//  Film Camera
//

import SwiftUI

/// Horizontal picker of the user's films, like a roll of film canisters.
struct FilmStrip: View {
    @Environment(FilmLibrary.self) private var library
    @Environment(CameraModel.self) private var camera
    var onBrowse: () -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    item(id: "none", title: "Original", isSelected: camera.selectedFilmID == nil) {
                        NoFilmThumbnail()
                    } action: {
                        Task { await camera.selectFilm(nil, lutURL: nil) }
                    }

                    ForEach(library.myFilms) { film in
                        item(id: film.id, title: film.displayName, isSelected: camera.selectedFilmID == film.id) {
                            FilmThumbnail(url: library.thumbnailURL(for: film))
                        } action: {
                            Task { await camera.selectFilm(film, lutURL: library.lutURL(for: film)) }
                        }
                    }

                    Button(action: onBrowse) {
                        VStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.title3.weight(.semibold))
                                .frame(width: 60, height: 60)
                                .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 14))
                            Text("More")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.secondary)
                        }
                        .frame(width: 68)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Browse Films")
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, 16, for: .scrollContent)
            .frame(height: 106)
            .onAppear {
                proxy.scrollTo(camera.selectedFilmID ?? "none", anchor: .center)
            }
            .onChange(of: camera.selectedFilmID) { _, id in
                withAnimation { proxy.scrollTo(id ?? "none", anchor: .center) }
            }
        }
        .sensoryFeedback(.selection, trigger: camera.selectedFilmID)
    }

    private func item(id: String, title: String, isSelected: Bool,
                      @ViewBuilder thumbnail: () -> some View,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                thumbnail()
                    .frame(width: 60, height: 60)
                    .clipShape(.rect(cornerRadius: 14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(isSelected ? Color.filmPrimary : .white.opacity(0.12), lineWidth: isSelected ? 2.5 : 1)
                    }
                    .scaleEffect(isSelected ? 1.06 : 1)
                Text(title)
                    .font(.caption2.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.filmPrimary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(width: 68)
            .animation(.spring(duration: 0.25), value: isSelected)
        }
        .buttonStyle(.plain)
        .id(id)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
