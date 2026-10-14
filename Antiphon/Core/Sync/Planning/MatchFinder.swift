import Foundation

/// Read access to one platform's catalog, in platform-neutral terms.
/// Live adapters wrap `SpotifyAPIClient` and `AppleMusicManager`.
protocol TrackCatalog: Sendable {
    var platform: Platform { get }
    func tracks(withISRC isrc: String) async throws -> [CatalogTrack]
    func search(_ query: String, limit: Int) async throws -> [CatalogTrack]
    /// Album type and year for catalog IDs whose tracks didn't come with them.
    func albums(for ids: [String]) async -> [String: AlbumDetails]
}

extension TrackCatalog {
    func albums(for ids: [String]) async -> [String: AlbumDetails] { [:] }
}

/// What a lookup knows about a track's album.
struct AlbumDetails: Equatable, Sendable {
    var kind: AlbumKind?
    /// The album's own year. Apple Music's song lookups give the song's, so a
    /// 2013 compilation of a 2004 song says 2004.
    var year: Int?
}

/// Finds a track's counterpart in another catalog and scores every candidate.
///
/// Same strategy as `TrackMatcher` — ISRC first, then a normalized
/// "artist title" search — but it keeps the scores, the reason and the
/// runners-up instead of returning only the best result.
enum MatchFinder {
    static let searchLimit = 5
    /// Same title, artist and length (or same ISRC): interchangeable recordings.
    static let strongMatch = 90

    static func find(
        _ source: CatalogTrack,
        in catalog: some TrackCatalog,
        targetPlaylist: [CatalogTrack],
        preferences: VersionPreferences = .standard
    ) async throws -> MatchOutcome {
        func candidate(_ source: CatalogTrack, _ track: CatalogTrack) -> MatchCandidate {
            Self.candidate(source, track, preferences: preferences)
        }

        var found: [CatalogTrack] = []

        if let isrc = source.isrc, !isrc.isEmpty, !isrc.hasPrefix("local-") {
            found = try await catalog.tracks(withISRC: isrc)
        }

        var scored = found.map { candidate(source, $0) }
        let plainQuery = "\(source.artist.normalizedForMatching) \(source.title.normalizedForMatching)"
        var searchedPlain = false
        if !scored.contains(where: { $0.reason == .isrc }) {
            scored += try await catalog.search(plainQuery, limit: searchLimit).map { candidate(source, $0) }
            searchedPlain = true
        }

        // The same recording often has a different ISRC on its original album
        // than on compilations. If no solid match is on the source's album,
        // look for the album version too.
        if let album = source.album,
           !scored.contains(where: { $0.confidence >= strongMatch && ReleasePreference.albumMatch($0.track, source) > 0 }) {
            let query = "\(source.artist.normalizedForMatching) \(source.title.normalizedForMatching) \(ReleasePreference.baseAlbum(album))"
            let results = try await catalog.search(query, limit: searchLimit)
            scored += results.map { candidate(source, $0) }
        }

        // Asked for the original album, but the ISRC only found compilations
        // or singles:
        // the studio album often has its own ISRC, so search for it too.
        if preferences.release == .original, !searchedPlain,
           !scored.contains(where: { candidate in
               candidate.confidence >= strongMatch && ReleasePreference.isStudioAlbum(candidate.track)
           }) {
            scored += try await catalog.search(plainQuery, limit: searchLimit).map { candidate(source, $0) }
        }

        // The original album needs to know compilations that don't say so
        // in their title ("It's Hard Rock, Hallelujah!"). So does the source's
        // album when it isn't among the solid matches: then "not a compilation"
        // decides, and Apple Music's lookups don't say which ones are.
        let unknown = scored.filter { $0.confidence >= strongMatch && $0.track.albumKind == nil }.map(\.track.id)
        let sourceAlbumMissing = preferences.release == .sourceAlbum && source.album != nil && !unknown.isEmpty
            && !ReleasePreference.isCompilation(source)
            && !scored.contains { $0.confidence >= strongMatch && ReleasePreference.albumMatch($0.track, source) > 0 }
        if preferences.release == .original || sourceAlbumMissing {
            let albums = await catalog.albums(for: Array(Set(unknown)))
            if !albums.isEmpty {
                scored = scored.map { candidate in
                    guard let album = albums[candidate.track.id] else { return candidate }
                    var track = candidate.track
                    if let kind = album.kind { track.albumKind = kind }
                    if let year = album.year { track.releaseYear = year }
                    return MatchCandidate(track: track, confidence: candidate.confidence, reason: candidate.reason)
                }
            }
        }

        var seen = Set<String>()
        let ranked = scored
            .sorted { a, b in
                // Every solid match is the same recording for practical
                // purposes, so among those the release decides (original
                // album over compilations); otherwise confidence decides.
                let strongA = a.confidence >= strongMatch, strongB = b.confidence >= strongMatch
                if strongA != strongB { return strongA }
                let releaseA = ReleasePreference.rank(a.track, for: source, choice: preferences.release)
                let releaseB = ReleasePreference.rank(b.track, for: source, choice: preferences.release)
                if strongA {
                    return releaseA != releaseB ? releaseA > releaseB : a.confidence > b.confidence
                }
                return a.confidence != b.confidence ? a.confidence > b.confidence : releaseA > releaseB
            }
            .filter { seen.insert($0.track.id).inserted }
            .prefix(searchLimit)

        guard let best = ranked.first else {
            return MatchOutcome(best: nil, alternatives: [], alreadyInTarget: false)
        }

        return MatchOutcome(
            best: best,
            alternatives: Array(ranked.dropFirst()),
            alreadyInTarget: best.confidence >= ConfidencePolicy.reviewFloor
                && targetPlaylist.contains { isSameRecording(best.track, $0) }
        )
    }

    /// Whether a playlist entry is the catalog track itself (same ID or ISRC),
    /// or the same title, artist and length.
    static func isSameRecording(_ a: CatalogTrack, _ b: CatalogTrack) -> Bool {
        if a.id == b.id { return true }
        let score = ConfidenceScorer.score(source: a, candidate: b)
        return score.reason == .isrc || (score.reason == .titleArtistDuration && score.confidence >= 90)
    }

    private static func candidate(_ source: CatalogTrack, _ track: CatalogTrack, preferences: VersionPreferences) -> MatchCandidate {
        let score = ConfidenceScorer.score(source: source, candidate: track, preferences: preferences)
        return MatchCandidate(track: track, confidence: score.confidence, reason: score.reason)
    }
}
