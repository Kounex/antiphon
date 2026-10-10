import Foundation
import SwiftData
import MusicKit

/// The track IDs a plan was built against, in order. If either playlist
/// changes before the plan is applied, the plan is stale and is rebuilt.
struct PlaylistFingerprint: Equatable, Sendable {
    let spotifyIds: [String]
    let appleMusicIds: [String]

    init(spotifyTracks: [SpotifyPlaylistItem], appleMusicTracks: [AppleMusicTrackInfo]) {
        spotifyIds = spotifyTracks.compactMap { $0.track?.uri }
        appleMusicIds = appleMusicTracks.map(\.id)
    }
}

/// A plan plus what it was built against.
struct PlannedSync: Sendable {
    let plan: SyncPlan
    let fingerprint: PlaylistFingerprint
    let sourcePlatform: Platform
}

/// Builds dry-run `SyncPlan`s from live playlist state without writing
/// anything to either platform or the store.
actor SyncPlanner {

    /// Called as each track is checked against the other catalog.
    typealias Progress = @Sendable (_ checked: Int, _ total: Int) async -> Void

    private let modelContainer: ModelContainer
    private let spotifyClient: SpotifyAPIClient
    private let appleMusicManager: AppleMusicManager
    private let confidence: ConfidencePolicy
    private let capabilities: PlatformCapabilities

    init(
        modelContainer: ModelContainer,
        spotifyClient: SpotifyAPIClient,
        appleMusicManager: AppleMusicManager,
        confidence: ConfidencePolicy,
        capabilities: PlatformCapabilities = .current
    ) {
        self.modelContainer = modelContainer
        self.spotifyClient = spotifyClient
        self.appleMusicManager = appleMusicManager
        self.confidence = confidence
        self.capabilities = capabilities
    }

    func plan(pairId: UUID, action: SyncAction = .manualSync, progress: Progress? = nil) async throws -> PlannedSync {
        let live = try await fetchLiveTracks(pairId: pairId)
        let stageA = try DryRunStageA.run(
            container: modelContainer, pairId: pairId, action: action,
            trackMatcher: TrackMatcher(spotifyClient: spotifyClient, appleMusicManager: appleMusicManager),
            spotifyTracks: live.spotify, appleMusicTracks: live.appleMusic
        )

        let toMatch = stageA.rows.filter { row in
            guard row.removalFlag == nil else { return false }
            let needsWork = row.state == .pending || (row.state == .failed && row.retryCount < PlanBuilder.maxRetries)
            return needsWork && PlanBuilder.allows(stageA.direction, from: row.source.platform)
        }

        let spotifyCatalog = SpotifyTrackCatalog(client: spotifyClient)
        let appleCatalog = AppleMusicTrackCatalog(manager: appleMusicManager)
        await appleCatalog.prefetch(isrcs: toMatch.filter { $0.source.platform == .spotify }.compactMap(\.source.isrc))

        let spotifyPlaylist = live.spotify.compactMap { $0.track.map(CatalogTrack.init) }
        let applePlaylist = live.appleMusic.map(CatalogTrack.init)

        var outcomes: [TrackKey: MatchOutcome] = [:]
        for (index, row) in toMatch.enumerated() {
            try Task.checkCancellation()
            await progress?(index, toMatch.count)
            outcomes[row.key] = row.source.platform == .spotify
                ? try await MatchFinder.find(row.source, in: appleCatalog, targetPlaylist: applePlaylist)
                : try await MatchFinder.find(row.source, in: spotifyCatalog, targetPlaylist: spotifyPlaylist)
        }
        await progress?(toMatch.count, toMatch.count)

        let plan = PlanBuilder.build(PlanInput(
            pairId: pairId,
            direction: stageA.direction,
            sourcePlatform: stageA.sourcePlatform,
            removalPolicy: stageA.removalPolicy,
            confidence: confidence,
            rows: stageA.rows,
            outcomes: outcomes,
            appleMusicCanRemove: capabilities.appleMusicCanRemove
        ))

        return PlannedSync(
            plan: plan,
            fingerprint: PlaylistFingerprint(spotifyTracks: live.spotify, appleMusicTracks: live.appleMusic),
            sourcePlatform: stageA.sourcePlatform
        )
    }

    // MARK: - Private

    /// Same fetches as the engine's Stage A. Playlists still waiting to be
    /// created count as empty.
    private func fetchLiveTracks(pairId: UUID) async throws -> (spotify: [SpotifyPlaylistItem], appleMusic: [AppleMusicTrackInfo]) {
        let context = ModelContext(modelContainer)
        guard let pair = try context.fetch(FetchDescriptor<SyncPair>(predicate: #Predicate { $0.id == pairId })).first else {
            throw DryRunStageA.Failure.pairNotFound
        }
        let spotifyId = pair.spotifyPlaylistId
        let appleId = pair.appleMusicPlaylistId

        // Same local ISRC lookup the engine builds, so Apple Music tracks
        // already known to the cache don't need a catalog round trip.
        var known: [String: String] = [:]
        for track in pair.cachedTracks {
            if let id = track.appleMusicTrackId, !track.isrc.hasPrefix("local-") { known[id] = track.isrc }
        }
        let localLookup = known
        let lookup: @Sendable ([String]) -> [String: String] = { ids in
            ids.reduce(into: [:]) { result, id in if let isrc = localLookup[id] { result[id] = isrc } }
        }

        let spotify = spotifyId.hasPrefix("pending-creation-")
            ? [] : try await spotifyClient.getPlaylistTracks(playlistId: spotifyId)

        guard !appleId.hasPrefix("pending-creation-") else { return (spotify, []) }
        let playlists = try await appleMusicManager.fetchUserPlaylists()
        guard let playlist = playlists.first(where: { $0.id.rawValue == appleId }) else {
            throw SyncError.appleMusicPlaylistNotFound
        }
        let appleMusic = try await appleMusicManager.fetchPlaylistTracks(for: playlist, localISRCLookup: lookup)
        return (spotify, appleMusic)
    }
}
