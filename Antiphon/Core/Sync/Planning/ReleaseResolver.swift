import Foundation

/// Picks the catalog release to add when only a library copy or another
/// platform's track is at hand — for example when putting a track back.
///
/// Uses the same ranking as syncing (original album over compilations), and
/// adds nothing rather than a doubtful version.
enum ReleaseResolver {
    static func catalogTrack(
        for track: CatalogTrack,
        in catalog: some TrackCatalog,
        preferences: VersionPreferences = .standard
    ) async throws -> CatalogTrack? {
        let outcome = try await MatchFinder.find(track, in: catalog, targetPlaylist: [], preferences: preferences)
        guard let best = outcome.best, best.confidence >= MatchFinder.strongMatch else { return nil }
        return best.track
    }
}
