import AntiphonDesign
import Foundation
import Observation

/// Both libraries in one grid.
@MainActor
@Observable
final class LibraryModel {
    var scope: LibraryScope = .both
    var filter: LibraryFilter = .noTwin
    var sort: LibrarySort = .library
    private(set) var items: [LibraryItem] = []
    private(set) var isLoading = false
    /// Sides that couldn't be read, with what to do about it.
    private(set) var failures: [Platform: String] = [:]

    private let library: LibraryService
    private let seams: SeamRepository

    init(library: LibraryService, seams: SeamRepository) {
        self.library = library
        self.seams = seams
    }

    func load() async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        async let spotify = playlists(on: .spotify)
        async let apple = playlists(on: .appleMusic)
        let (s, a) = await (spotify, apple)
        let seamed = (try? await seams.seams()) ?? []
        items = LibraryGrid.items(spotify: s, appleMusic: a, seams: seamed)
    }

    var visible: [LibraryItem] { LibraryGrid.visible(items, scope: scope, filter: filter, sort: sort) }

    var chips: [ChipBar<LibraryFilter>.Chip] {
        let counts = LibraryGrid.counts(items, scope: scope)
        return [.init(.noTwin, "No twin yet", count: counts[.noTwin]),
                .init(.inSeam, "In a seam", count: counts[.inSeam]),
                .init(.madeByMe, "Made by me", count: counts[.madeByMe])]
    }

    var emptyMessage: String {
        switch filter {
        case .noTwin: "Every playlist here already has a twin."
        case .inSeam: "No playlist here is in a seam yet."
        case .madeByMe: "No playlists you made here."
        }
    }

    private func playlists(on platform: Platform) async -> [LibraryPlaylist] {
        do {
            let result = try await library.playlists(on: platform)
            failures[platform] = nil
            return result
        } catch {
            failures[platform] = "Antiphon couldn't read your \(platform.rawValue) playlists. Check the connection in Settings."
            return []
        }
    }
}

/// A playlist without a twin: what's in it, and how much of it the other
/// catalog has, before a seam is made.
@MainActor
@Observable
final class PlaylistDetailModel {
    let playlist: LibraryPlaylist
    private(set) var entries: [LibraryEntry] = []
    private(set) var isLoading = true
    private(set) var loadError: String?
    private(set) var report: AvailabilityReport?
    private(set) var isChecking = false

    private let library: LibraryService
    private let availability: AvailabilityService

    init(playlist: LibraryPlaylist, library: LibraryService, availability: AvailabilityService) {
        self.playlist = playlist
        self.library = library
        self.availability = availability
    }

    var other: Platform { playlist.platform.other }

    /// Apple Music checks a Spotify playlist in a few batched requests, so
    /// that runs on open. The other way costs a search per track: on request.
    var checksAutomatically: Bool { playlist.platform == .spotify }

    func load() async {
        defer { isLoading = false }
        do {
            entries = try await library.entries(of: playlist)
            loadError = nil
        } catch {
            loadError = "Antiphon couldn't read this playlist."
            return
        }
        if checksAutomatically { await checkAvailability() }
    }

    func checkAvailability() async {
        guard !isChecking, !entries.isEmpty else { return }
        isChecking = true
        defer { isChecking = false }
        report = AvailabilityReport(total: entries.count)
        let final = try? await availability.check(entries.map(\.track), on: other) { [weak self] partial in
            await MainActor.run { self?.report = partial }
        }
        if let final { report = final }
    }

    var header: String {
        PlaylistCopy.header(playlist, trackCount: entries.isEmpty ? (playlist.trackCount ?? 0) : entries.count,
                            durationMs: entries.compactMap(\.track.durationMs).reduce(0, +))
    }

    var availabilityText: String {
        PlaylistCopy.availability(report ?? AvailabilityReport(total: entries.count), on: other)
    }

    /// 0…1 for the availability bar.
    var availableFraction: Double {
        guard let report, report.total > 0 else { return 0 }
        return Double(report.available.count) / Double(report.total)
    }

    func isMissing(_ entry: LibraryEntry) -> Bool { report?.missing.contains(entry.track.id) ?? false }
    func isClose(_ entry: LibraryEntry) -> Bool { report?.close.contains(entry.track.id) ?? false }

    func detail(for entry: LibraryEntry) -> String {
        PlaylistCopy.trackDetail(artist: entry.track.artist, addedBy: playlist.isCollaborative ? entry.addedBy : nil,
                                 isMissing: isMissing(entry), other: other)
    }
}

/// Search both libraries: tracks in seams, playlist names on both sides,
/// artists. Everything is local; nothing is sent while typing.
@MainActor
@Observable
final class SearchModel {
    enum Scope: Hashable, CaseIterable { case tracks, playlists, artists }

    var query = ""
    var scope: Scope = .tracks
    private(set) var index: [IndexedTrack] = []
    private(set) var playlists: [LibraryItem] = []
    private(set) var recent: [String]

    private let trackIndex: TrackIndex
    private let library: LibraryModel
    private let preferences: AppPreferences

    init(index: TrackIndex, library: LibraryModel, preferences: AppPreferences) {
        self.trackIndex = index
        self.library = library
        self.preferences = preferences
        recent = preferences.recentSearches
    }

    func load() async {
        index = (try? await trackIndex.indexedTracks()) ?? []
        if library.items.isEmpty { await library.load() }
        playlists = library.items
    }

    var trackHits: [TrackHit] { LibrarySearch.tracks(query, in: index) }
    var playlistHits: [LibraryItem] { LibrarySearch.playlists(query, in: playlists) }
    var artistHits: [ArtistHit] { LibrarySearch.artists(query, in: index) }

    var isEmptyQuery: Bool { LibrarySearch.fold(query).isEmpty }

    var heading: String {
        switch scope {
        case .tracks: "Tracks matching “\(query.trimmingCharacters(in: .whitespaces))”"
        case .playlists: "Playlists matching “\(query.trimmingCharacters(in: .whitespaces))”"
        case .artists: "Artists matching “\(query.trimmingCharacters(in: .whitespaces))”"
        }
    }

    var hasResults: Bool {
        switch scope {
        case .tracks: !trackHits.isEmpty
        case .playlists: !playlistHits.isEmpty
        case .artists: !artistHits.isEmpty
        }
    }

    func commit() {
        recent = RecentSearches.adding(query, to: recent)
        preferences.recentSearches = recent
    }

    func use(_ recentQuery: String) {
        query = recentQuery
        commit()
    }

    func clearRecent() {
        recent = []
        preferences.recentSearches = []
    }

    /// An artist result shows that artist's tracks.
    func show(_ artist: ArtistHit) {
        query = artist.name
        scope = .tracks
        commit()
    }
}
