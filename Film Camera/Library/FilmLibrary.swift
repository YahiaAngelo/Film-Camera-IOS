//
//  FilmLibrary.swift
//  Film Camera
//

import Foundation
import Observation
import SwiftUI

/// The film catalog from github.com/YahiaAngelo/Film-Luts plus the user's
/// downloaded ("My Films") collection, stored on device for offline use.
@Observable
final class FilmLibrary {
    static let repositoryURL = URL(string: "https://raw.githubusercontent.com/YahiaAngelo/Film-Luts/main/")!
    static let catalogURL = repositoryURL.appending(path: "film_luts.json")

    /// Films shipped inside the app so it works offline from the first launch.
    static let bundledIDs: [String] = [
        "luts/negative_new/kodak_portra_400.cube",
        "luts/negative_color/kodak_ektar_100.cube",
        "luts/negative_old/fuji_superia_400.cube",
        "luts/fujixtransiii/fuji_xtrans_iii_classic_chrome.cube",
        "luts/colorslide/fuji_velvia_50.cube",
        "luts/print/kodak_2383_cuspclip.cube",
        "luts/bw/kodak_tri-x_400.cube",
        "luts/bw/ilford_hp_5_plus_400.cube",
    ]

    private(set) var films: [Film] = []
    /// Ordered IDs of films the user has on device.
    private(set) var myFilmIDs: [String] {
        didSet { UserDefaults.standard.set(myFilmIDs, forKey: Keys.myFilms) }
    }
    private(set) var downloading: Set<String> = []
    /// Progress of a "Download All" run, `nil` when none is running.
    private(set) var bulkDownload: BulkDownloadProgress?
    private var bulkDownloadTask: Task<Void, Never>?
    private(set) var isRefreshing = false
    var errorMessage: String?

    private var filmsByID: [String: Film] = [:]
    private let storageURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Films", directoryHint: .isDirectory)
    }()

    private enum Keys {
        static let myFilms = "myFilms"
    }

    init() {
        myFilmIDs = UserDefaults.standard.stringArray(forKey: Keys.myFilms) ?? Self.bundledIDs
        loadCachedCatalog()
    }

    // MARK: - Queries

    var myFilms: [Film] { myFilmIDs.compactMap { filmsByID[$0] } }

    /// Categories in catalog order.
    var categories: [String] {
        var seen = Set<String>()
        return films.map(\.category).filter { seen.insert($0).inserted }
    }

    func film(id: String?) -> Film? {
        id.flatMap { filmsByID[$0] }
    }

    func isBundled(_ film: Film) -> Bool { Self.bundledIDs.contains(film.id) }

    func isInMyFilms(_ film: Film) -> Bool { myFilmIDs.contains(film.id) }

    /// Local `.cube` file for a film, if it's bundled or downloaded.
    func lutURL(for film: Film) -> URL? {
        let downloaded = storageURL.appending(path: film.lutFile)
        if FileManager.default.fileExists(atPath: downloaded.path) { return downloaded }
        if isBundled(film) { return Bundle.main.url(forResource: film.fileStem, withExtension: "cube") }
        return nil
    }

    /// Local thumbnail if available, otherwise the remote one.
    func thumbnailURL(for film: Film) -> URL {
        let downloaded = storageURL.appending(path: film.thumbnail)
        if FileManager.default.fileExists(atPath: downloaded.path) { return downloaded }
        if isBundled(film), let bundled = Bundle.main.url(forResource: film.fileStem, withExtension: "jpg") { return bundled }
        return Self.repositoryURL.appending(path: film.thumbnail)
    }

    // MARK: - Catalog

    private var cachedCatalogURL: URL { storageURL.appending(path: "film_luts.json") }

    private func loadCachedCatalog() {
        let urls = [cachedCatalogURL, Bundle.main.url(forResource: "film_luts", withExtension: "json")].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(FilmCatalog.self, from: data) {
                setFilms(catalog.filmLUTs)
                return
            }
        }
    }

    /// Fetches the latest catalog, keeping the cached one when offline.
    func refreshCatalog() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let (data, response) = try await URLSession.shared.data(from: Self.catalogURL)
            try Self.validate(response)
            let catalog = try JSONDecoder().decode(FilmCatalog.self, from: data)
            setFilms(catalog.filmLUTs)
            try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
            try data.write(to: cachedCatalogURL, options: .atomic)
        } catch {
            // Offline: the cached or bundled catalog is still usable.
        }
    }

    private func setFilms(_ newFilms: [Film]) {
        // The catalog lists categories in filesystem order; sort names within each for browsing.
        let order = ["Negative New", "Negative Color", "Negative Old", "Colorslide", "Print", "Fujixtransiii", "Bw", "Instant Consumer", "Instant Pro"]
        films = newFilms.sorted {
            let a = order.firstIndex(of: $0.category) ?? order.count
            let b = order.firstIndex(of: $1.category) ?? order.count
            return a == b ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : a < b
        }
        filmsByID = Dictionary(films.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Downloads

    /// Adds a film to My Films, downloading its LUT and thumbnail if needed.
    @discardableResult
    func download(_ film: Film, reportsErrors: Bool = true) async -> Bool {
        if lutURL(for: film) != nil {
            addToMyFilms(film)
            return true
        }
        guard !downloading.contains(film.id) else { return false }
        downloading.insert(film.id)
        defer { downloading.remove(film.id) }

        do {
            let lutDestination = storageURL.appending(path: film.lutFile)
            let (data, response) = try await URLSession.shared.data(from: Self.repositoryURL.appending(path: film.lutFile))
            try Self.validate(response)
            // Make sure it's a valid LUT before keeping it (parsed off the main thread).
            try await Task.detached(priority: .utility) {
                _ = try CubeLUT(parsing: String(decoding: data, as: UTF8.self))
            }.value
            try FileManager.default.createDirectory(at: lutDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: lutDestination, options: .atomic)

            // The thumbnail is nice to have offline, but not required.
            let thumbDestination = storageURL.appending(path: film.thumbnail)
            if let (thumb, thumbResponse) = try? await URLSession.shared.data(from: Self.repositoryURL.appending(path: film.thumbnail)),
               (try? Self.validate(thumbResponse)) != nil {
                try? FileManager.default.createDirectory(at: thumbDestination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? thumb.write(to: thumbDestination, options: .atomic)
            }

            addToMyFilms(film)
            return true
        } catch {
            if reportsErrors {
                errorMessage = "Couldn't download \(film.displayName). \(error.localizedDescription)"
            }
            return false
        }
    }

    /// Films from `films` that aren't in My Films yet.
    func notYetDownloaded(_ films: [Film]) -> [Film] {
        films.filter { !isInMyFilms($0) }
    }

    /// Downloads several films, a few at a time. Keeps running if the library
    /// sheet is closed; cancel with `cancelBulkDownload()`.
    func downloadAll(_ films: [Film]) {
        let pending = notYetDownloaded(films)
        guard bulkDownloadTask == nil, !pending.isEmpty else { return }
        bulkDownload = BulkDownloadProgress(total: pending.count)

        bulkDownloadTask = Task {
            var failed = 0
            await withTaskGroup(of: Bool.self) { group in
                var queue = pending.makeIterator()
                for _ in 0..<Self.bulkConcurrency {
                    guard let film = queue.next() else { break }
                    group.addTask { await self.download(film, reportsErrors: false) }
                }
                while let succeeded = await group.next() {
                    if !succeeded { failed += 1 }
                    bulkDownload?.completed += 1
                    guard !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    if let film = queue.next() {
                        group.addTask { await self.download(film, reportsErrors: false) }
                    }
                }
            }
            if failed > 0 {
                errorMessage = failed == 1
                    ? "1 film couldn't be downloaded. Check your connection and try again."
                    : "\(failed) films couldn't be downloaded. Check your connection and try again."
            }
            bulkDownload = nil
            bulkDownloadTask = nil
        }
    }

    func cancelBulkDownload() {
        bulkDownloadTask?.cancel()
    }

    private static let bulkConcurrency = 6

    /// Removes a film from My Films and deletes any downloaded files.
    func remove(_ film: Film) {
        myFilmIDs.removeAll { $0 == film.id }
        try? FileManager.default.removeItem(at: storageURL.appending(path: film.lutFile))
        try? FileManager.default.removeItem(at: storageURL.appending(path: film.thumbnail))
    }

    func moveMyFilms(from source: IndexSet, to destination: Int) {
        myFilmIDs.move(fromOffsets: source, toOffset: destination)
    }

    private func addToMyFilms(_ film: Film) {
        if !myFilmIDs.contains(film.id) { myFilmIDs.append(film.id) }
    }

    /// Rough on-disk size of a film (LUT + thumbnail), for the download prompt.
    static let approximateBytesPerFilm: Int64 = 165_000

    private static func validate(_ response: URLResponse) throws {
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }
    }
}

struct BulkDownloadProgress: Equatable {
    let total: Int
    var completed = 0

    var fraction: Double { total == 0 ? 1 : Double(completed) / Double(total) }
}
