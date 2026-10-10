import Foundation

/// Read access to one platform's catalog, in platform-neutral terms.
/// Live adapters wrap `SpotifyAPIClient` and `AppleMusicManager`.
protocol TrackCatalog: Sendable {
    var platform: Platform { get }
    func tracks(withISRC isrc: String) async throws -> [CatalogTrack]
    func search(_ query: String, limit: Int) async throws -> [CatalogTrack]
}

/// Finds a track's counterpart in another catalog and scores every candidate.
///
/// Same strategy as `TrackMatcher` — ISRC first, then a normalized
/// "artist title" search — but it keeps the scores, the reason and the
/// runners-up instead of returning only the best result.
enum MatchFinder {
    static let searchLimit = 5

    static func find(
        _ source: CatalogTrack,
        in catalog: some TrackCatalog,
        targetPlaylist: [CatalogTrack]
    ) async throws -> MatchOutcome {
        var found: [CatalogTrack] = []

        if let isrc = source.isrc, !isrc.isEmpty, !isrc.hasPrefix("local-") {
            found = try await catalog.tracks(withISRC: isrc)
        }

        var scored = found.map { candidate(source, $0) }
        if !scored.contains(where: { $0.reason == .isrc }) {
            let query = "\(source.artist.normalizedForMatching) \(source.title.normalizedForMatching)"
            let results = try await catalog.search(query, limit: searchLimit)
            scored += results.map { candidate(source, $0) }
        }

        var seen = Set<String>()
        let ranked = scored
            .sorted { a, b in
                // Equal confidence (e.g. one ISRC on the original album and on
                // compilations): prefer the original release.
                a.confidence != b.confidence
                    ? a.confidence > b.confidence
                    : ReleasePreference.prefers(a.track, over: b.track, for: source)
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

    private static func candidate(_ source: CatalogTrack, _ track: CatalogTrack) -> MatchCandidate {
        let score = ConfidenceScorer.score(source: source, candidate: track)
        return MatchCandidate(track: track, confidence: score.confidence, reason: score.reason)
    }
}
