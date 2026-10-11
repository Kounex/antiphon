import Foundation

// MARK: - Library grid

enum LibraryScope: Hashable, CaseIterable, Sendable {
    case both, spotify, appleMusic

    func includes(_ platform: Platform) -> Bool {
        switch self {
        case .both: true
        case .spotify: platform == .spotify
        case .appleMusic: platform == .appleMusic
        }
    }
}

enum LibraryFilter: Hashable, CaseIterable, Sendable {
    case noTwin, inSeam, madeByMe
}

enum LibrarySort: Hashable, CaseIterable, Sendable {
    /// As each platform lists them, Spotify first.
    case library, name, size
}

/// A playlist in the grid, with the seam it belongs to, if any.
struct LibraryItem: Identifiable, Hashable, Sendable {
    let playlist: LibraryPlaylist
    let seam: SeamSummary?
    /// The line under the cover.
    let detail: String

    var id: String { "\(playlist.platform.rawValue):\(playlist.id)" }
}

/// Both libraries in one grid. The default filter is the playlists with no
/// twin, because that's where the next seam comes from.
enum LibraryGrid {
    static func items(spotify: [LibraryPlaylist], appleMusic: [LibraryPlaylist], seams: [SeamSummary]) -> [LibraryItem] {
        var seamByPlaylist: [String: SeamSummary] = [:]
        for seam in seams {
            seamByPlaylist["\(Platform.spotify.rawValue):\(seam.spotify.playlistId)"] = seam
            seamByPlaylist["\(Platform.appleMusic.rawValue):\(seam.appleMusic.playlistId)"] = seam
        }
        return (spotify + appleMusic).map { playlist in
            let seam = seamByPlaylist["\(playlist.platform.rawValue):\(playlist.id)"]
            return LibraryItem(playlist: playlist, seam: seam, detail: detail(playlist, seam: seam))
        }
    }

    static func detail(_ playlist: LibraryPlaylist, seam: SeamSummary?) -> String {
        if seam != nil { return "Stitched to \(playlist.platform.other.rawValue)" }
        if playlist.blockedReason != nil { return playlist.detail }
        guard let count = playlist.trackCount else { return "No twin yet" }
        return "\(PlanCopy.count(count, "track")) · no twin"
    }

    static func matches(_ item: LibraryItem, _ filter: LibraryFilter) -> Bool {
        switch filter {
        case .noTwin: item.seam == nil
        case .inSeam: item.seam != nil
        case .madeByMe: item.playlist.isOwn && item.playlist.blockedReason == nil
        }
    }

    static func visible(_ items: [LibraryItem], scope: LibraryScope, filter: LibraryFilter, sort: LibrarySort) -> [LibraryItem] {
        let shown = items.filter { scope.includes($0.playlist.platform) && matches($0, filter) }
        switch sort {
        case .library:
            return shown
        case .name:
            return shown.sorted { $0.playlist.name.localizedStandardCompare($1.playlist.name) == .orderedAscending }
        case .size:
            // Stable: equal sizes keep library order; unknown sizes go last.
            return shown.enumerated().sorted { a, b in
                let x = a.element.playlist.trackCount ?? -1, y = b.element.playlist.trackCount ?? -1
                return x != y ? x > y : a.offset < b.offset
            }.map(\.element)
        }
    }

    static func counts(_ items: [LibraryItem], scope: LibraryScope) -> [LibraryFilter: Int] {
        let inScope = items.filter { scope.includes($0.playlist.platform) }
        return Dictionary(uniqueKeysWithValues: LibraryFilter.allCases.map { filter in
            (filter, inScope.filter { matches($0, filter) }.count)
        })
    }
}

// MARK: - A playlist without a twin

/// What the other catalog has of a playlist, filled in as it's checked.
struct AvailabilityReport: Equatable, Sendable {
    var total: Int
    var checked = 0
    /// Track IDs with a solid match on the other side.
    var available: Set<String> = []
    /// Track IDs with only a close match (a different version).
    var close: Set<String> = []
    var missing: Set<String> = []

    var isComplete: Bool { checked >= total }
}

enum PlaylistCopy {
    /// "7 h 41 min", "42 min".
    static func duration(ms: Int) -> String? {
        let minutes = ms / 60_000
        guard minutes > 0 else { return nil }
        return minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
    }

    /// "Spotify · collaborative · 112 tracks · 7 h 41 min".
    static func header(_ playlist: LibraryPlaylist, trackCount: Int, durationMs: Int) -> String {
        var parts = [playlist.platform.rawValue]
        if playlist.isCollaborative { parts.append("collaborative") }
        parts.append(PlanCopy.count(trackCount, "track"))
        if let length = duration(ms: durationMs) { parts.append(length) }
        return parts.joined(separator: " · ")
    }

    static func availability(_ report: AvailabilityReport, on platform: Platform) -> String {
        let name = platform.rawValue
        guard report.checked > 0 else { return "Not checked against \(name) yet." }
        guard report.isComplete else { return "Checking \(report.checked) of \(report.total) tracks on \(name)…" }
        if report.available.count == report.total {
            return "All \(PlanCopy.count(report.total, "track")) are available on \(name)."
        }
        var rest: [String] = []
        if !report.close.isEmpty {
            rest.append(report.close.count == 1 ? "1 has only a close match" : "\(report.close.count) have only a close match")
        }
        if !report.missing.isEmpty {
            rest.append(report.missing.count == 1 ? "1 wasn't found there" : "\(report.missing.count) weren't found there")
        }
        let lead = "\(report.available.count) of \(PlanCopy.count(report.total, "track")) are available on \(name)."
        return rest.isEmpty ? lead : "\(lead) \(rest.joined(separator: ", "))."
    }

    static func trackDetail(artist: String, addedBy: AddedBy?, name: String? = nil, isMissing: Bool, other: Platform) -> String {
        if isMissing { return "\(artist) · not on \(other.rawValue)" }
        switch addedBy {
        case .you: return "\(artist) · added by you"
        case .collaborator: return "\(artist) · added by \(name ?? "a collaborator")"
        case nil: return artist
        }
    }
}

// MARK: - Search

struct SeamRef: Hashable, Sendable {
    let id: UUID
    let name: String
}

/// One cached track of one seam, for local search. Only seamed playlists
/// are indexed.
struct IndexedTrack: Hashable, Sendable {
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let seam: SeamRef
    let onSpotify: Bool
    let onAppleMusic: Bool
}

/// A track and which playlists, on which side, already hold it.
struct TrackHit: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let spotify: [SeamRef]
    let appleMusic: [SeamRef]

    func seams(on platform: Platform) -> [SeamRef] { platform == .spotify ? spotify : appleMusic }
}

struct ArtistHit: Identifiable, Hashable, Sendable {
    let name: String
    let trackCount: Int
    let seams: [SeamRef]
    var id: String { name }
}

enum LibrarySearch {
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tracks whose title, artist or album contains the query, one result
    /// per recording. Titles starting with the query come first.
    static func tracks(_ query: String, in index: [IndexedTrack]) -> [TrackHit] {
        let q = fold(query)
        guard !q.isEmpty else { return [] }
        var groups: [String: [IndexedTrack]] = [:]
        var order: [String] = []
        for track in index where [track.title, track.artist, track.album ?? ""].contains(where: { fold($0).contains(q) }) {
            let key = "\(fold(track.title))|\(fold(track.artist))"
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(track)
        }
        let hits = order.compactMap { key -> TrackHit? in
            guard let tracks = groups[key], let first = tracks.first else { return nil }
            func refs(_ on: (IndexedTrack) -> Bool) -> [SeamRef] {
                var seen = Set<UUID>()
                return tracks.filter(on).map(\.seam).filter { seen.insert($0.id).inserted }
            }
            return TrackHit(id: key, title: first.title, artist: first.artist, album: first.album ?? tracks.compactMap(\.album).first,
                            artworkURL: tracks.compactMap(\.artworkURL).first,
                            spotify: refs(\.onSpotify), appleMusic: refs(\.onAppleMusic))
        }
        return ranked(hits, by: \.title, query: q)
    }

    static func artists(_ query: String, in index: [IndexedTrack]) -> [ArtistHit] {
        let q = fold(query)
        guard !q.isEmpty else { return [] }
        var byArtist: [String: [IndexedTrack]] = [:]
        for track in index where fold(track.artist).contains(q) { byArtist[track.artist, default: []].append(track) }
        let hits = byArtist.map { name, tracks in
            var seen = Set<UUID>()
            return ArtistHit(name: name, trackCount: Set(tracks.map { fold($0.title) }).count,
                             seams: tracks.map(\.seam).filter { seen.insert($0.id).inserted })
        }
        return ranked(hits, by: \.name, query: q)
    }

    static func playlists(_ query: String, in items: [LibraryItem]) -> [LibraryItem] {
        let q = fold(query)
        guard !q.isEmpty else { return [] }
        return ranked(items.filter { fold($0.playlist.name).contains(q) }, by: \.playlist.name, query: q)
    }

    /// "3 playlists", "Garden Sundays", "not on Apple Music".
    static func sideText(_ seams: [SeamRef], on platform: Platform) -> String {
        switch seams.count {
        case 0: "not on \(platform.rawValue)"
        case 1: seams[0].name
        default: "\(seams.count) playlists"
        }
    }

    private static func ranked<T>(_ items: [T], by name: KeyPath<T, String>, query: String) -> [T] {
        items.sorted { a, b in
            let x = fold(a[keyPath: name]), y = fold(b[keyPath: name])
            let px = x.hasPrefix(query), py = y.hasPrefix(query)
            return px != py ? px : x < y
        }
    }
}

enum RecentSearches {
    static let limit = 6

    static func adding(_ query: String, to recent: [String]) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return recent }
        let rest = recent.filter { LibrarySearch.fold($0) != LibrarySearch.fold(trimmed) }
        return Array(([trimmed] + rest).prefix(limit))
    }
}
