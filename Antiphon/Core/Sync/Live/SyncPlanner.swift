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
    private let versionPreferences: VersionPreferences
    /// Overrides the per-seam capabilities (tests, previews).
    private let capabilities: PlatformCapabilities?

    init(
        modelContainer: ModelContainer,
        spotifyClient: SpotifyAPIClient,
        appleMusicManager: AppleMusicManager,
        confidence: ConfidencePolicy,
        versionPreferences: VersionPreferences = .standard,
        capabilities: PlatformCapabilities? = nil
    ) {
        self.versionPreferences = versionPreferences
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
        var unchecked = 0
        for (index, row) in toMatch.enumerated() {
            try Task.checkCancellation()
            await progress?(index, toMatch.count)
            do {
                let outcome = row.source.platform == .spotify
                    ? try await MatchFinder.find(row.source, in: appleCatalog, targetPlaylist: applePlaylist, preferences: versionPreferences)
                    : try await MatchFinder.find(row.source, in: spotifyCatalog, targetPlaylist: spotifyPlaylist, preferences: versionPreferences)
                outcomes[row.key] = outcome
                #if DEBUG
                let candidates = ([outcome.best].compactMap { $0 } + outcome.alternatives)
                    .map { "\($0.track.album ?? "?") (\($0.track.releaseYear.map(String.init) ?? "?")) \($0.confidence)% \($0.track.isrc ?? "-")" }
                print("[SyncPlanner] '\(row.source.title)' from [\(row.source.album ?? "?")] isrc \(row.source.isrc ?? "-") → \(candidates.joined(separator: " | "))")
                #endif
            } catch {
                switch CatalogFailure.classify(error) {
                case .cancelled: throw error
                case .stop(let message):
                    print("[SyncPlanner] Stopping preview: \(error)")
                    throw PlanningStopped(message: message)
                case .skipTrack:
                    // Left out of the plan, so it stays pending and is checked next time.
                    print("[SyncPlanner] Skipping '\(row.source.title)': \(error)")
                    unchecked += 1
                }
            }
        }
        await progress?(toMatch.count, toMatch.count)

        var plan = PlanBuilder.build(PlanInput(
            pairId: pairId,
            direction: stageA.direction,
            sourcePlatform: stageA.sourcePlatform,
            removalPolicy: stageA.removalPolicy,
            confidence: confidence,
            rows: stageA.rows,
            outcomes: outcomes,
            appleMusicCanRemove: (capabilities ?? live.capabilities).appleMusicCanRemove
        ))
        plan.uncheckedCount = unchecked

        return PlannedSync(
            plan: plan,
            fingerprint: PlaylistFingerprint(spotifyTracks: live.spotify, appleMusicTracks: live.appleMusic),
            sourcePlatform: stageA.sourcePlatform
        )
    }

    // MARK: - Private

    /// Same fetches as the engine's Stage A. Playlists still waiting to be
    /// created count as empty.
    private func fetchLiveTracks(pairId: UUID) async throws -> LiveTracks {
        let context = ModelContext(modelContainer)
        guard let pair = try context.fetch(FetchDescriptor<SyncPair>(predicate: #Predicate { $0.id == pairId })).first else {
            throw DryRunStageA.Failure.pairNotFound
        }
        let spotifyId = pair.spotifyPlaylistId
        let appleId = pair.appleMusicPlaylistId
        // A playlist Antiphon is about to create counts as Antiphon's.
        let capabilities = PlatformCapabilities.forSeam(
            appleMusicCreatedByAntiphon: pair.appleMusicCreatedByAntiphon || appleId.hasPrefix("pending-creation-")
        )

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

        guard !appleId.hasPrefix("pending-creation-") else {
            return LiveTracks(spotify: spotify, appleMusic: [], capabilities: capabilities)
        }
        let playlists = try await appleMusicManager.fetchUserPlaylists()
        guard let playlist = playlists.first(where: { $0.id.rawValue == appleId }) else {
            throw SyncError.appleMusicPlaylistNotFound
        }
        let appleMusic = try await appleMusicManager.fetchPlaylistTracks(for: playlist, localISRCLookup: lookup)
        return LiveTracks(spotify: spotify, appleMusic: appleMusic, capabilities: capabilities)
    }

    private struct LiveTracks {
        let spotify: [SpotifyPlaylistItem]
        let appleMusic: [AppleMusicTrackInfo]
        let capabilities: PlatformCapabilities
    }
}
