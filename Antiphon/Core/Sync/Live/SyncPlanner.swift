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

/// How long a background run may spend looking tracks up. iOS gives a
/// background refresh about 30 seconds and planning keeps nothing until it's
/// applied, so planning stops in time to apply what it has; the rest waits
/// for the next run. At least one track is always looked up, so a slow
/// connection still makes progress.
struct LookupBudget: Sendable {
    let limit: Duration?
    let startedAt: ContinuousClock.Instant

    init(_ limit: Duration?, startedAt: ContinuousClock.Instant = .now) {
        self.limit = limit
        self.startedAt = startedAt
    }

    static var unlimited: LookupBudget { LookupBudget(nil) }

    func allowsLookup(done: Int, at now: ContinuousClock.Instant = .now) -> Bool {
        guard let limit, done > 0 else { return true }
        return now - startedAt < limit
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
    private let recheck: RecheckCadence

    init(
        modelContainer: ModelContainer,
        spotifyClient: SpotifyAPIClient,
        appleMusicManager: AppleMusicManager,
        confidence: ConfidencePolicy,
        versionPreferences: VersionPreferences = .standard,
        capabilities: PlatformCapabilities? = nil,
        recheck: RecheckCadence = .weekly
    ) {
        self.recheck = recheck
        self.versionPreferences = versionPreferences
        self.modelContainer = modelContainer
        self.spotifyClient = spotifyClient
        self.appleMusicManager = appleMusicManager
        self.confidence = confidence
        self.capabilities = capabilities
    }

    /// `unattended`: a background run applies the plan without a preview.
    /// Its `removeInBackground` decides whether Mirror removals are carried
    /// out, and tracks are looked up only while `lookupTime` lasts (see
    /// `LookupBudget`); the rest stay pending for the next run.
    struct Unattended: Sendable {
        let removeInBackground: Bool
        let lookupTime: Duration
    }

    /// Up-front ISRC lookups for a background run, so a huge batch doesn't
    /// spend the budget before planning starts.
    private static let unattendedPrefetch = 100

    func plan(pairId: UUID, action: SyncAction = .manualSync, progress: Progress? = nil,
              unattended: Unattended? = nil) async throws -> PlannedSync {
        // Counts the playlist reads too: the whole plan has to fit.
        let budget = LookupBudget(unattended?.lookupTime)
        let live = try await fetchLiveTracks(pairId: pairId)
        let stageA = try DryRunStageA.run(
            container: modelContainer, pairId: pairId, action: action,
            trackMatcher: TrackMatcher(),
            spotifyTracks: live.spotify, appleMusicTracks: live.appleMusic
        )

        let candidates = stageA.rows.filter { row in
            guard row.removalFlag == nil else { return false }
            let needsWork = row.state == .pending || (row.state == .failed
                && AvailabilityRecheck.isDue(retryCount: row.retryCount, lastAttempt: row.lastAttempt, cadence: recheck, now: Date()))
            return needsWork && PlanBuilder.allows(stageA.direction, from: row.source.platform)
        }
        let toMatch = candidates

        let spotifyCatalog = SpotifyTrackCatalog(client: spotifyClient)
        let appleCatalog = AppleMusicTrackCatalog(manager: appleMusicManager)
        let prefetching = toMatch.filter { $0.source.platform == .spotify }.compactMap(\.source.isrc)
        await appleCatalog.prefetch(isrcs: unattended == nil ? prefetching : Array(prefetching.prefix(Self.unattendedPrefetch)))

        let spotifyPlaylist = live.spotify.compactMap { $0.track.map(CatalogTrack.init) }
        let applePlaylist = live.appleMusic.map(CatalogTrack.init)

        var outcomes: [TrackKey: MatchOutcome] = [:]
        var unchecked = 0
        for (index, row) in toMatch.enumerated() {
            try Task.checkCancellation()
            guard budget.allowsLookup(done: index) else {
                // Out of time: the rest stay pending for the next run.
                unchecked += toMatch.count - index
                print("[SyncPlanner] Looked up \(index) of \(toMatch.count) in the time a background run has; the rest wait")
                break
            }
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
                    throw PlanningStopped(message: message, underlying: error)
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
            removalPolicy: unattended.map {
                PlanBuilder.unattendedPolicy(stageA.removalPolicy, removeInBackground: $0.removeInBackground)
            } ?? stageA.removalPolicy,
            confidence: confidence,
            rows: stageA.rows,
            outcomes: outcomes,
            appleMusicCanRemove: (capabilities ?? live.capabilities).appleMusicCanRemove,
            recheck: recheck
        ))
        plan.uncheckedCount = unchecked
        if let target = live.mirrorTarget {
            let ids: [Platform: [String]] = [.spotify: spotifyPlaylist.map(\.id), .appleMusic: applePlaylist.map(\.id)]
            let reorder = PlacementStep.mirroredIDs(target: ids[target] ?? [], reference: ids[target.other] ?? [],
                                                    rows: stageA.rows.map(PlacementStep.Row.init), on: target)
            plan.reorders = reorder == nil ? nil : target
        }

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
        let mirrorTarget = pair.mirrorTarget
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
            return LiveTracks(spotify: spotify, appleMusic: [], capabilities: capabilities, mirrorTarget: nil)
        }
        let playlists = try await appleMusicManager.fetchUserPlaylists()
        guard let playlist = playlists.first(where: { $0.id.rawValue == appleId }) else {
            throw SyncError.appleMusicPlaylistNotFound
        }
        let appleMusic = try await appleMusicManager.fetchPlaylistTracks(for: playlist, localISRCLookup: lookup)
        return LiveTracks(spotify: spotify, appleMusic: appleMusic, capabilities: capabilities, mirrorTarget: mirrorTarget)
    }

    private struct LiveTracks {
        let spotify: [SpotifyPlaylistItem]
        let appleMusic: [AppleMusicTrackInfo]
        let capabilities: PlatformCapabilities
        /// "Same order": the playlist that follows the other side.
        let mirrorTarget: Platform?
    }
}
