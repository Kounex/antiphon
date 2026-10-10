import Foundation
import SwiftData

/// Runs the engine's Stage A (dedupe, align, prune, target matching) on a
/// throwaway context and reports the resulting cache state as `PlanRow`s.
///
/// Every step runs with `persist: false` and the context is rolled back, so
/// the store is never written: this is what makes previews dry runs.
enum DryRunStageA {

    struct Result {
        let rows: [PlanRow]
        let sourcePlatform: Platform
        let direction: SyncDirection
        let removalPolicy: RemovalPolicy
        let isInitialSync: Bool
    }

    enum Failure: Error {
        case pairNotFound
    }

    static func run(
        container: ModelContainer,
        pairId: UUID,
        action: SyncAction,
        trackMatcher: TrackMatcher,
        spotifyTracks: [SpotifyPlaylistItem],
        appleMusicTracks: [AppleMusicTrackInfo]
    ) throws -> Result {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        defer { context.rollback() }

        guard let pair = try context.fetch(FetchDescriptor<SyncPair>(predicate: #Predicate { $0.id == pairId })).first else {
            throw Failure.pairNotFound
        }

        var descriptor = FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.syncPair?.id == pairId })
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .forward)]
        var cached = try context.fetch(descriptor)

        cached = PlaylistCachePruner.deduplicate(in: context, cachedTracksFetch: cached, persist: false)

        let isSpotifySource = CacheAligner.isSpotifySource(
            direction: pair.syncDirection,
            spotifyCount: spotifyTracks.count,
            appleMusicCount: appleMusicTracks.count
        )
        let isInitialSync = action == .initialSync || action == .fullRebuild || cached.isEmpty || pair.needsRebuild

        if !isInitialSync {
            DeltaEngine.reanchorAppleMusicIds(cachedTracks: cached, appleMusicTracks: appleMusicTracks, trackMatcher: trackMatcher)
        }

        cached = CacheAligner.alignCache(
            in: context, pair: pair, cachedTracks: cached,
            spotifyTracks: spotifyTracks, appleMusicTracks: appleMusicTracks,
            isInitialSync: isInitialSync, isSpotifySource: isSpotifySource, persist: false
        )
        cached = PlaylistCachePruner.pruneGoneTracks(
            in: context, cachedTracks: cached,
            liveSpotifyURIs: Set(spotifyTracks.compactMap { $0.track?.uri }),
            liveAppleIDs: Set(appleMusicTracks.map(\.id)),
            persist: false
        )
        cached = DeltaEngine.matchTargetTracks(
            in: context, pair: pair, cachedTracks: cached,
            spotifyTracks: spotifyTracks, appleMusicTracks: appleMusicTracks,
            isInitialSync: isInitialSync, isSpotifySource: isSpotifySource,
            trackMatcher: trackMatcher, persist: false
        )

        let sourcePlatform: Platform = isSpotifySource ? .spotify : .appleMusic
        return Result(
            rows: cached.compactMap { $0.planRow(seamSource: sourcePlatform) },
            sourcePlatform: sourcePlatform,
            direction: pair.syncDirection,
            removalPolicy: pair.effectiveRemovalPolicy,
            isInitialSync: isInitialSync
        )
    }
}

extension CachedTrack {
    /// The platform this row was loaded from. Rows on both sides belong to the seam's source.
    func homePlatform(seamSource: Platform) -> Platform {
        switch source {
        case .spotify: .spotify
        case .appleMusic: .appleMusic
        case .both: seamSource
        }
    }

    /// The key planning and applying agree on for this row.
    func planKey(seamSource: Platform) -> TrackKey? {
        let home = homePlatform(seamSource: seamSource)
        guard let id = home == .spotify ? spotifyTrackUri : appleMusicTrackId else { return nil }
        return TrackKey(platform: home, id: id)
    }

    func planRow(seamSource: Platform) -> PlanRow? {
        guard let key = planKey(seamSource: seamSource) else { return nil }
        let counterpart = key.platform == .spotify ? appleMusicTrackId : spotifyTrackUri
        return PlanRow(
            source: CatalogTrack(
                platform: key.platform, id: key.id, title: title, artist: artist, album: albumName,
                durationMs: durationMs, isrc: isrc.hasPrefix("local-") ? nil : isrc, artworkURL: artworkURL
            ),
            counterpartId: counterpart,
            state: effectiveSyncState,
            removalFlag: removalFlag,
            removalKept: removalKeptAt != nil,
            retryCount: retryCount,
            removalFlaggedAt: removalFlaggedAt
        )
    }
}
