import Foundation
import SwiftData
import MusicKit
import os

/// Progress callback type — called after each track is processed.
typealias SyncProgressCallback = @Sendable (SyncProgress) async -> Void

/// Process-wide registry of SyncPair IDs with an in-progress sync. UI-triggered syncs,
/// background refresh, and AppIntents each create their own SyncEngine instance, so
/// per-instance state cannot enforce mutual exclusion across engines.
private let inProgressSyncPairs = OSAllocatedUnfairLock(initialState: Set<UUID>())

/// Central sync engine that performs bidirectional delta synchronization
/// between Spotify and Apple Music playlists.
///
/// This actor implements a two-stage sync model:
/// Stage A: Fetch remote state and populate the cache (fast, shows track list immediately)
/// Stage B: Match tracks one-by-one on the target platform (slow, shows per-track progress)
///
/// Supports cancellation checkpoints, resumable sync, and retry logic.
/// Thread-safe by design as a Swift actor.
actor SyncEngine {
    
    private let modelContainer: ModelContainer
    private let spotifyClient: SpotifyAPIClient
    private let appleMusicManager: AppleMusicManager
    private let trackMatcher: TrackMatcher
    
    init(
        modelContainer: ModelContainer,
        spotifyClient: SpotifyAPIClient,
        appleMusicManager: AppleMusicManager
    ) {
        self.modelContainer = modelContainer
        self.spotifyClient = spotifyClient
        self.appleMusicManager = appleMusicManager
        self.trackMatcher = TrackMatcher()
    }
    
    // MARK: - Public API
    
    /// Performs a delta sync for all monitored SyncPairs.
    /// Called by foreground sync, AppIntent, and BGAppRefreshTask.
    @discardableResult
    /// `only`: the seams a background run found due; `nil` syncs every monitored seam.
    func syncAllMonitored(only: Set<UUID>? = nil, trigger: SyncTrigger = .monitor,
                          preferences: AppPreferences = .shared) async -> [SyncResult] {
        let context = ModelContext(modelContainer)
        
        let descriptor = FetchDescriptor<SyncPair>(
            // A seam's first sync is always previewed by the person, never run
            // by monitoring.
            // A rebuild (after a direction change) is previewed by the person too.
            predicate: #Predicate {
                $0.isMonitored == true && $0.pausedAt == nil && $0.lastSyncedAt != nil && $0.needsRebuild == false
            }
        )
        
        guard let monitoredPairs = try? context.fetch(descriptor) else {
            return []
        }
        
        // Prioritize interrupted pairs (they have pending work)
        let sorted = monitoredPairs.sorted { a, b in
            if a.lastInterruptedAt != nil && b.lastInterruptedAt == nil { return true }
            if a.lastInterruptedAt == nil && b.lastInterruptedAt != nil { return false }
            return (a.lastSyncedAt ?? .distantPast) < (b.lastSyncedAt ?? .distantPast)
        }
        
        var results: [SyncResult] = []
        
        for pair in sorted {
            // Check cancellation between pairs
            if Task.isCancelled { break }
            if let only, !only.contains(pair.id) { continue }
            
            // Skip pairs synced recently (per-pair cooldown)
            if let lastSync = pair.lastSyncedAt,
               Date().timeIntervalSince(lastSync) < AppConstants.Sync.minimumSyncIntervalSeconds {
                continue
            }
            
            let result = await monitorSync(pair, context: context, trigger: trigger, preferences: preferences)
            results.append(result)
        }
        
        try? context.save()
        
        return results
    }
    
    /// A run nobody previews applies the same plan a preview would show,
    /// approving nothing: strong matches are added, close matches wait in
    /// Review, removals follow the seam's policy (Mirror removes unless
    /// "Removals in the background" is off, Ask asks).
    private func monitorSync(_ pair: SyncPair, context: ModelContext, trigger: SyncTrigger,
                             preferences: AppPreferences) async -> SyncResult {
        // A sync already running for this seam (started by the person) wins;
        // don't plan against playlists it is changing.
        let pairId = pair.id
        guard !inProgressSyncPairs.withLock({ $0.contains(pairId) }) else {
            return SyncResult(pairId: pair.id, status: .partial, message: SyncError.syncAlreadyInProgress.localizedDescription)
        }
        let planner = SyncPlanner(
            modelContainer: modelContainer, spotifyClient: spotifyClient, appleMusicManager: appleMusicManager,
            confidence: preferences.confidencePolicy, versionPreferences: preferences.versionPreferences,
            recheck: preferences.recheckCadence
        )
        let startedAt = Date()
        let planned: PlannedSync
        do {
            planned = try await planner.plan(pairId: pair.id, action: .monitorSync, unattended: .init(
                removeInBackground: preferences.removeInBackground, limit: AppConstants.Sync.backgroundLookupLimit
            ))
        } catch {
            // iOS ending the background run cancels the requests in flight.
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return SyncResult(pairId: pair.id, status: .partial, message: "Sync interrupted")
            }
            return failedRun(error, pair: pair, context: context, action: .monitorSync, trigger: trigger, startedAt: startedAt)
        }
        // If a playlist changes between planning and applying, nothing is
        // written (`isStale`) and the next run plans again.
        return await syncSinglePair(pair, context: context, action: .monitorSync,
                                    run: RunContext(trigger: trigger, planned: planned))
    }

    /// Records a run that stopped on `error`: the seam's state, a problem
    /// the person can act on (if it is one), and the History entry.
    private func failedRun(_ error: any Error, pair: SyncPair, context: ModelContext, action: SyncAction,
                           trigger: SyncTrigger, startedAt: Date, changes: [SyncChange] = [],
                           tracksAdded: Int = 0, tracksFailed: Int = 0) -> SyncResult {
        let message = "Sync failed: \((error as? PlanningStopped)?.message ?? error.localizedDescription)"
        pair.lastSyncResult = .failed
        pair.lastSyncMessage = message
        let cause = (error as? PlanningStopped)?.underlying ?? error
        if let problem = ProblemClassifier.problem(for: cause, seamName: pair.spotifyPlaylistName) {
            ProblemStore.record(problem, for: pair, in: context)
        }
        writeLog(pair: pair, context: context, action: action, trigger: trigger, startedAt: startedAt, changes: changes,
                 result: .failed, tracksAdded: tracksAdded, tracksRemoved: 0,
                 tracksFailed: tracksFailed, tracksMatched: 0, details: message)
        return SyncResult(pairId: pair.id, status: .failed, message: message)
    }

    /// Performs a sync for a specific SyncPair.
    /// Accepts an optional progress callback for real-time UI updates.
    @discardableResult
    func syncPair(
        _ pairId: UUID,
        action: SyncAction = .manualSync,
        trigger: SyncTrigger? = nil,
        planned: PlannedSync,
        approving approved: Set<TrackKey> = [],
        progressCallback: SyncProgressCallback? = nil
    ) async -> SyncResult {
        let context = ModelContext(modelContainer)
        
        let descriptor = FetchDescriptor<SyncPair>(
            predicate: #Predicate { pair in pair.id == pairId }
        )
        
        guard let pair = try? context.fetch(descriptor).first else {
            return SyncResult(pairId: pairId, status: .failed, message: "SyncPair not found")
        }
        
        let result = await syncSinglePair(
            pair, context: context, action: action,
            run: RunContext(trigger: trigger ?? SyncTrigger(action), planned: planned, approved: approved),
            progressCallback: progressCallback
        )
        try? context.save()
        
        return result
    }
    
    // MARK: - Core Sync Algorithm
    
    private func syncSinglePair(
        _ pair: SyncPair,
        context: ModelContext,
        action: SyncAction,
        run: RunContext,
        progressCallback: SyncProgressCallback? = nil
    ) async -> SyncResult {
        
        // Cross-engine mutual exclusion: every caller (UI, background, AppIntent)
        // builds a fresh SyncEngine, so the registry must live outside the actor.
        let pairId = pair.id
        guard inProgressSyncPairs.withLock({ $0.insert(pairId).inserted }) else {
            // Report as partial (not failed) so background callers don't fire
            // spurious failure notifications for an overlapping sync.
            let message = SyncError.syncAlreadyInProgress.localizedDescription
            pair.lastSyncResult = .partial
            pair.lastSyncMessage = message
            return SyncResult(pairId: pairId, status: .partial, message: message)
        }
        defer { _ = inProgressSyncPairs.withLock { $0.remove(pairId) } }
        
        let previousResult = pair.lastSyncResult
        let previousMessage = pair.lastSyncMessage
        pair.lastSyncResult = .inProgress
        pair.lastSyncMessage = nil
        
        var tracksAdded = 0
        var tracksFailed = 0
        
        // ── Fetch local database cache (Exactly 1 query for the entire sync run) ──
        var cachedTrackDescriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate { $0.syncPair?.id == pairId }
        )
        cachedTrackDescriptor.sortBy = [SortDescriptor(\.addedAt, order: .forward)]
        var cachedTracks = (try? context.fetch(cachedTrackDescriptor)) ?? []
        
        do {
            // Deduplicate cached tracks using PlaylistCachePruner
            cachedTracks = PlaylistCachePruner.deduplicate(in: context, cachedTracksFetch: cachedTracks)
            
            // Extract Sendable data from non-Sendable cachedTracks references prior to crossing actor boundary
            var tempLookupDict: [String: String] = [:]
            for track in cachedTracks {
                if let amId = track.appleMusicTrackId, !track.isrc.hasPrefix("local-") {
                    tempLookupDict[amId] = track.isrc
                }
            }
            let localLookupDict = tempLookupDict
            
            let localISRCLookup: @Sendable ([String]) -> [String: String] = { ids in
                var result: [String: String] = [:]
                for id in ids {
                    if let isrc = localLookupDict[id] {
                        result[id] = isrc
                    }
                }
                return result
            }
            
            // Stage A, then Stage B applies the plan.
            
            // ── Step 0: Create pending playlists if needed ──
            
            if pair.appleMusicPlaylistId.hasPrefix("pending-creation-") {
                let newPlaylist = try await appleMusicManager.createPlaylist(
                    name: pair.appleMusicPlaylistName,
                    description: "Synced from Spotify by Antiphon"
                )
                pair.appleMusicPlaylistId = newPlaylist.id.rawValue
                pair.appleMusicCreatedByAntiphon = true
            }
            
            if pair.spotifyPlaylistId.hasPrefix("pending-creation-") {
                let newPlaylist = try await spotifyClient.createPlaylist(
                    name: pair.spotifyPlaylistName,
                    description: "Synced from Apple Music by Antiphon"
                )
                pair.spotifyPlaylistId = newPlaylist.id
                pair.spotifyCreatedByAntiphon = true
                pair.spotifySnapshotId = newPlaylist.snapshotId
                pair.spotifyImageURL = newPlaylist.images?.first?.url
            }
            
            // ── Step 1: Fetch tracks from both platforms in parallel ──
            let amPlaylists = try await appleMusicManager.fetchUserPlaylists()
            guard let amPlaylist = amPlaylists.first(where: { $0.id.rawValue == pair.appleMusicPlaylistId }) else {
                throw SyncError.appleMusicPlaylistNotFound
            }
            
            let spotifyId = pair.spotifyPlaylistId
            
            async let spotifyTracksFetch = spotifyClient.getPlaylistTracks(
                playlistId: spotifyId
            )
            async let appleMusicTracksFetch = appleMusicManager.fetchPlaylistTracks(
                for: amPlaylist,
                localISRCLookup: localISRCLookup
            )
            
            let (spotifyTracksResult, appleMusicTracksResult) = try await (spotifyTracksFetch, appleMusicTracksFetch)
            let spotifyTracks = spotifyTracksResult
            let appleMusicTracks = appleMusicTracksResult

            // Either playlist changed since the preview: don't apply a plan
            // the person didn't see. The caller previews again.
            if PlaylistFingerprint(spotifyTracks: spotifyTracks, appleMusicTracks: appleMusicTracks) != run.planned.fingerprint {
                pair.lastSyncResult = previousResult
                pair.lastSyncMessage = previousMessage
                var result = SyncResult(pairId: pair.id, status: .partial, message: "Playlists changed since the preview")
                result.isStale = true
                return result
            }
            
            // Determine isSpotifySource dynamically for bidirectional initial sync
            let isSpotifySource = CacheAligner.isSpotifySource(
                direction: pair.syncDirection,
                spotifyCount: spotifyTracks.count,
                appleMusicCount: appleMusicTracks.count
            )
            run.seamSource = isSpotifySource ? .spotify : .appleMusic
            
            // ── Step 2: Populate cache with source tracks immediately ──
            let isInitialSync = action == .initialSync || action == .fullRebuild || cachedTracks.isEmpty || pair.needsRebuild
            
            // Rows flagged from here on are this sync's new removals.
            let alignStartedAt = Date()
            let removalSnapshot = RemovalSafety.Snapshot(cachedTracks)

            // Rows matched in Stage B (or manually) may hold a catalog Song ID
            // rather than the playlist's library ID. Re-anchor them before
            // any step compares against the live library IDs.
            if !isInitialSync {
                DeltaEngine.reanchorAppleMusicIds(
                    cachedTracks: cachedTracks,
                    appleMusicTracks: appleMusicTracks,
                    trackMatcher: trackMatcher
                )
            }
            
            cachedTracks = CacheAligner.alignCache(
                in: context,
                pair: pair,
                cachedTracks: cachedTracks,
                spotifyTracks: spotifyTracks,
                appleMusicTracks: appleMusicTracks,
                isInitialSync: isInitialSync,
                isSpotifySource: isSpotifySource
            )
            
            // Report total tracks count based on source playlist fetch
            let sourceCount = isSpotifySource ? spotifyTracks.count : appleMusicTracks.count
            await progressCallback?(SyncProgress(
                totalTracks: sourceCount,
                completedTracks: 0,
                failedTracks: 0,
                currentTrackName: "Fetched source playlist..."
            ))
            
            // ── Step 3b: Sync artwork (Apple Music → Spotify, initial sync only) ──
            // Only onto a Spotify playlist Antiphon created for this seam:
            // replacing the cover of a playlist the person already had is
            // a write the preview never shows.
            if isInitialSync && pair.spotifyCreatedByAntiphon {
                do {
                    if let base64JPEG = try await appleMusicManager.fetchPlaylistArtworkAsBase64JPEG(for: amPlaylist) {
                        try await spotifyClient.uploadPlaylistImage(
                            playlistId: pair.spotifyPlaylistId,
                            base64JPEG: base64JPEG
                        )
                    }
                } catch {
                    print("[SyncEngine] Artwork sync failed (non-critical): \(error.localizedDescription)")
                }
            }
            
            // ── Step 4: Perform matching with target tracks and update cache ──
            let liveSpotifyURIs = Set(spotifyTracks.compactMap { $0.track?.uri })
            let liveAppleIDs = Set(appleMusicTracks.map { $0.id })
            
            // Prune tracks no longer in either live playlist
            cachedTracks = PlaylistCachePruner.pruneGoneTracks(
                in: context,
                cachedTracks: cachedTracks,
                liveSpotifyURIs: liveSpotifyURIs,
                liveAppleIDs: liveAppleIDs
            )
            
            // Match remaining tracks with target using DeltaEngine
            cachedTracks = DeltaEngine.matchTargetTracks(
                in: context,
                pair: pair,
                cachedTracks: cachedTracks,
                spotifyTracks: spotifyTracks,
                appleMusicTracks: appleMusicTracks,
                isInitialSync: isInitialSync,
                isSpotifySource: isSpotifySource,
                trackMatcher: trackMatcher
            )
            
            // Safety check on removals
            if !isInitialSync && RemovalSafety.shouldStop(cachedTracks, since: alignStartedAt) {
                let totalRemovals = RemovalSafety.newRemovals(in: cachedTracks, since: alignStartedAt)
                let removalPercentage = Double(totalRemovals) / Double(cachedTracks.count)
                let message = "Safety threshold triggered: \(totalRemovals) tracks would be removed (\(Int(removalPercentage * 100))%). Sync aborted."
                // Nothing was removed: put the flags back so the next
                // sync looks at the same rows afresh.
                removalSnapshot.restore(cachedTracks)
                pair.lastSyncResult = .failed
                pair.lastSyncMessage = message
                logSync(pair: pair, context: context, action: action, run: run,
                       result: .failed,
                       tracksAdded: 0, tracksRemoved: 0, tracksFailed: 0,
                       tracksMatched: cachedTracks.count, details: message)
                return SyncResult(pairId: pair.id, status: .failed, message: message)
            }
            
            // ══════════════════════════════════════════════════
            // ── STAGE B: Match tracks one-by-one ──
            // ══════════════════════════════════════════════════
            
            let recheck = AppPreferences.shared.recheckCadence
            let now = Date()
            let pendingTracks = cachedTracks.filter {
                $0.syncState == .pending || ($0.syncState == .failed
                    && AvailabilityRecheck.isDue(retryCount: $0.retryCount, lastAttempt: $0.lastSyncAttempt, cadence: recheck, now: now))
            }
            let totalTracks = cachedTracks.count
            let alreadyCompleted = totalTracks - pendingTracks.count
            
            // Report initial progress
            await progressCallback?(SyncProgress(
                totalTracks: totalTracks,
                completedTracks: alreadyCompleted,
                failedTracks: 0,
                currentTrackName: nil
            ))
            
            let matchResult = try await matchTracksOneByOne(
                pendingTracks: pendingTracks,
                pair: pair,
                context: context,
                amPlaylist: amPlaylist,
                spotifyTracks: spotifyTracks,
                appleMusicTracks: appleMusicTracks,
                action: action,
                totalTracks: totalTracks,
                alreadyCompleted: alreadyCompleted,
                run: run,
                progressCallback: progressCallback
            )
            
            tracksAdded = matchResult.added
            tracksFailed = matchResult.failed
            
            // Check if we were cancelled
            if Task.isCancelled {
                return handleInterruption(pair: pair, context: context, action: action,
                                        tracksAdded: tracksAdded, tracksFailed: tracksFailed,
                                        cachedTracks: cachedTracks, run: run)
            }
            
            // Mirrored removals the plan showed (Apple Music only in playlists
            // Antiphon created, D1).
            let removed = try await applyPlannedRemovals(run.planned.plan, pair: pair, amPlaylist: amPlaylist,
                                                         cachedTracks: cachedTracks, run: run)
            if !removed.isEmpty {
                let removedIds = Set(removed.map(\.id))
                cachedTracks.removeAll { removedIds.contains($0.id) }
                removed.forEach(context.delete)
                try? context.save()
            }
            
            await placeAddedTracks(pair: pair, cachedTracks: cachedTracks, run: run)

            // ── Final: Log result ──
            let totalRemovalFlags = cachedTracks.filter { $0.removalFlag != nil }.count
            let totalUnmatched = cachedTracks.filter { $0.unmatchedPlatform != nil || $0.effectiveSyncState == .failed }.count
            let totalMatched = cachedTracks.count
            let resultStatus = SyncResultStatus.after(cachedTracks)
            
            let message = buildSyncMessage(
                flagged: totalRemovalFlags,
                unmatched: totalUnmatched,
                review: cachedTracks.filter { $0.removalFlag == nil && $0.effectiveSyncState == .needsReview }.count,
                total: totalMatched
            )
            
            pair.lastSyncedAt = Date()
            pair.needsRebuild = false
            ProblemStore.resolveAll(for: pair, in: context)
            pair.lastSyncResult = resultStatus
            pair.lastSyncMessage = message
            pair.lastInterruptedAt = nil
            
            logSync(
                pair: pair, context: context, action: action, run: run,
                result: resultStatus,
                tracksAdded: tracksAdded,
                tracksRemoved: run.removedCount,
                tracksFailed: totalUnmatched, tracksMatched: totalMatched - totalRemovalFlags - totalUnmatched,
                details: message
            )
            
            return SyncResult(
                pairId: pair.id,
                status: resultStatus,
                message: message,
                tracksAdded: tracksAdded,
                tracksFlagged: totalRemovalFlags,
                tracksFailed: tracksFailed
            )
            
        } catch is CancellationError {
            // User cancellation (or task teardown) arriving mid-write must resume
            // later, not be reported as a failure — the queued writes were already
            // rolled back to .pending inside matchTracksOneByOne.
            return handleInterruption(pair: pair, context: context, action: action,
                                      tracksAdded: tracksAdded, tracksFailed: tracksFailed,
                                      cachedTracks: cachedTracks, run: run)
        } catch {
            return failedRun(error, pair: pair, context: context, action: action,
                             trigger: run.trigger, startedAt: run.startedAt, changes: run.takeChanges(),
                             tracksAdded: tracksAdded, tracksFailed: tracksFailed)
        }
    }
    
    // MARK: - Per-Track Matching (Stage B)
    
    private struct MatchResult {
        var added: Int
        var failed: Int
    }
    
    /// A track queued for a Spotify batch write, with the state needed to roll
    /// the track back to .pending if the write never lands on the target playlist.
    private struct QueuedSpotifyWrite {
        let track: CachedTrack
        let uri: String
        let originalSource: TrackSource
    }
    
    /// A track queued for an Apple Music batch write, with the state needed to roll
    /// the track back to .pending if the write never lands on the target playlist.
    private struct QueuedAppleMusicWrite {
        let track: CachedTrack
        let songId: String
        let originalSource: TrackSource
    }
    
    /// Matches pending tracks one-by-one with cancellation checkpoints and progress reporting.
    private func matchTracksOneByOne(
        pendingTracks: [CachedTrack],
        pair: SyncPair,
        context: ModelContext,
        amPlaylist: Playlist?,
        spotifyTracks: [SpotifyPlaylistItem],
        appleMusicTracks: [AppleMusicTrackInfo],
        action: SyncAction,
        totalTracks: Int,
        alreadyCompleted: Int,
        run: RunContext,
        progressCallback: SyncProgressCallback?
    ) async throws -> MatchResult {
        var added = 0
        var failed = 0
        var completed = alreadyCompleted
        
        // Batch URIs for Spotify additions
        var spotifyUrisToAdd: [String] = []
        
        // Batch songs for Apple Music additions
        var appleMusicSongsToAdd: [Song] = []
        
        // Tracks paired with their queued writes, so batch-write failures and
        // interruptions can roll unwritten tracks back to .pending
        var queuedSpotifyWrites: [QueuedSpotifyWrite] = []
        var queuedAppleMusicWrites: [QueuedAppleMusicWrite] = []
        
        // The plan already chose each match; only its Apple Music songs need loading.
        let plannedSongs = await resolvePlannedSongs(run)
        
        for track in pendingTracks {
            // Cancellation checkpoint
            if Task.isCancelled {
                break
            }
            
            let originalSource = track.source
            
            // Mark as syncing
            track.syncState = .syncing
            track.lastSyncAttempt = Date()
            
            // Report progress
            // `completed` already includes failed tracks; don't count them twice
            await progressCallback?(SyncProgress(
                totalTracks: totalTracks,
                completedTracks: completed - failed,
                failedTracks: failed,
                currentTrackName: track.title
            ))
            
            // Do what the preview showed, nothing else.
            let plannedMatch: MatchCandidate
            switch applyDecision(to: track, run: run) {
            case .write(let match):
                plannedMatch = match
            case .settled(let didFail):
                if didFail { failed += 1 }
                completed += 1
                try? context.save()
                continue
            }

            if plannedMatch.track.platform == .appleMusic {
                if let song = plannedSongs[plannedMatch.track.id] {
                    // Check if already in target playlist
                    let existingAppleTrack = appleMusicTracks.first { appleTrack in
                        trackMatcher.isMatch(song: song, appleTrack: appleTrack)
                    }

                    if existingAppleTrack == nil {
                        appleMusicSongsToAdd.append(song)
                        queuedAppleMusicWrites.append(QueuedAppleMusicWrite(
                            track: track,
                            songId: song.id.rawValue,
                            originalSource: originalSource
                        ))
                        added += 1
                    } else {
                        print("[SyncEngine] Track '\(track.title)' already exists in Apple Music target playlist. Skipping add.")
                    }

                    // Prefer the playlist's library ID, which is what later
                    // syncs compare against. A freshly added song only has
                    // its catalog ID here; it's anchored after the write.
                    track.appleMusicTrackId = existingAppleTrack?.id ?? song.id.rawValue
                    track.syncState = .synced
                    track.source = .both
                    track.unmatchedPlatform = nil
                    recordEvidence(plannedMatch, on: track)
                } else {
                    // The plan found it, but fetching the song failed
                    // (network): it isn't missing. Try again next sync.
                    track.syncState = .pending
                }
            } else {
                let spotifyTrack = SpotifyTrack(catalog: plannedMatch.track)
                // Check if already in target playlist
                let alreadyExists = spotifyTracks.contains { spotifyItem in
                    trackMatcher.isMatch(spotifyTrack: spotifyTrack, spotifyItem: spotifyItem)
                }

                if !alreadyExists {
                    spotifyUrisToAdd.append(spotifyTrack.uri)
                    queuedSpotifyWrites.append(QueuedSpotifyWrite(
                        track: track,
                        uri: spotifyTrack.uri,
                        originalSource: originalSource
                    ))
                    added += 1
                } else {
                    print("[SyncEngine] Track '\(track.title)' already exists in Spotify target playlist. Skipping add.")
                }

                track.spotifyTrackUri = spotifyTrack.uri
                track.syncState = .synced
                track.source = .both
                track.unmatchedPlatform = nil
                recordEvidence(plannedMatch, on: track)
            }

            completed += 1
            
            // Save after each track for live UI updates and crash resilience
            try? context.save()
        }
        
        // If cancelled between marking tracks .synced and the batch writes below,
        // the queued tracks never reached the target playlist. Roll them back to
        // .pending so the next sync re-adds them instead of trusting the cache.
        if Task.isCancelled {
            let rolledBack = rollbackUnwrittenWrites(
                spotifyWrites: queuedSpotifyWrites,
                unwrittenSpotifyURIs: Set(queuedSpotifyWrites.map(\.uri)),
                appleMusicWrites: queuedAppleMusicWrites,
                unwrittenAppleSongIds: Set(queuedAppleMusicWrites.map(\.songId)),
                context: context
            )
            added -= rolledBack
            // Rolled back once: nothing is left to write or roll back below.
            spotifyUrisToAdd.removeAll()
            queuedSpotifyWrites.removeAll()
            appleMusicSongsToAdd.removeAll()
            queuedAppleMusicWrites.removeAll()
        }
        
        // Batch-add Spotify tracks if any
        if !spotifyUrisToAdd.isEmpty && !Task.isCancelled {
            await progressCallback?(SyncProgress(
                totalTracks: spotifyUrisToAdd.count,
                completedTracks: 0,
                failedTracks: 0,
                phase: .adding(platformName: "Spotify")
            ))
            do {
                try await spotifyClient.addTracksToPlaylist(
                    playlistId: pair.spotifyPlaylistId,
                    trackUris: spotifyUrisToAdd
                )
                for write in queuedSpotifyWrites {
                    run.recordAdd(of: write.track, on: .spotify, id: write.uri)
                }
            } catch {
                // Roll affected tracks back to .pending and fail the sync instead
                // of silently reporting success for writes that never landed. The
                // AM block below never runs after this throw, so its queued writes
                // must be rolled back here too.
                let rolledBack = rollbackUnwrittenWrites(
                    spotifyWrites: queuedSpotifyWrites,
                    unwrittenSpotifyURIs: Set(spotifyUrisToAdd),
                    appleMusicWrites: queuedAppleMusicWrites,
                    unwrittenAppleSongIds: Set(queuedAppleMusicWrites.map(\.songId)),
                    context: context
                )
                added -= rolledBack
                failed += rolledBack
                throw error
            }
        }
        
        // Batch-add Apple Music tracks if any
        if !appleMusicSongsToAdd.isEmpty {
            if Task.isCancelled {
                // Cancelled before the write: the tracks never reached the playlist,
                // so roll them back instead of leaving .synced rows the cache trusts.
                let rolledBack = rollbackUnwrittenWrites(
                    spotifyWrites: [],
                    unwrittenSpotifyURIs: [],
                    appleMusicWrites: queuedAppleMusicWrites,
                    unwrittenAppleSongIds: Set(queuedAppleMusicWrites.map(\.songId)),
                    context: context
                )
                added -= rolledBack
            } else {
                guard let amPlaylist = amPlaylist else {
                    let rolledBack = rollbackUnwrittenWrites(
                        spotifyWrites: [],
                        unwrittenSpotifyURIs: [],
                        appleMusicWrites: queuedAppleMusicWrites,
                        unwrittenAppleSongIds: Set(queuedAppleMusicWrites.map(\.songId)),
                        context: context
                    )
                    added -= rolledBack
                    failed += rolledBack
                    throw SyncError.appleMusicPlaylistNotFound
                }
                do {
                    let songCount = appleMusicSongsToAdd.count
                    let reportAdded: @Sendable (Int) async -> Void = { addedCount in
                        await progressCallback?(SyncProgress(
                            totalTracks: songCount,
                            completedTracks: addedCount,
                            failedTracks: 0,
                            phase: .adding(platformName: "Apple Music")
                        ))
                    }
                    await reportAdded(0)
                    try await appleMusicManager.addTracks(
                        appleMusicSongsToAdd,
                        to: amPlaylist,
                        onSongAdded: reportAdded
                    )
                    // Recorded under the ID the row keeps (the library ID once
                    // anchored), so seam detail can tell which rows are new.
                    let anchors = await appleMusicManager.libraryIDs(for: appleMusicSongsToAdd, in: amPlaylist)
                    for write in queuedAppleMusicWrites {
                        let id = anchors[write.songId] ?? write.songId
                        write.track.appleMusicTrackId = id
                        run.recordAdd(of: write.track, on: .appleMusic, id: id)
                    }
                } catch {
                    // Songs are added one at a time, so only roll back the ones
                    // that never reached the playlist.
                    var unwrittenSongIds = Set(queuedAppleMusicWrites.map(\.songId))
                    var underlying = error
                    if case AppleMusicError.partialAdd(let addedSongIds, let partialError) = error {
                        unwrittenSongIds.subtract(addedSongIds)
                        underlying = partialError
                        for write in queuedAppleMusicWrites where addedSongIds.contains(write.songId) {
                            run.recordAdd(of: write.track, on: .appleMusic, id: write.songId)
                        }
                    }
                    let rolledBack = rollbackUnwrittenWrites(
                        spotifyWrites: [],
                        unwrittenSpotifyURIs: [],
                        appleMusicWrites: queuedAppleMusicWrites,
                        unwrittenAppleSongIds: unwrittenSongIds,
                        context: context
                    )
                    added -= rolledBack
                    if !(underlying is CancellationError) {
                        failed += rolledBack
                    }
                    throw underlying
                }
            }
        }
        
        return MatchResult(added: added, failed: failed)
    }
    
    /// Rolls back queued tracks that were marked .synced but whose writes never landed
    /// on the target playlist, restoring their pre-match state so a later sync retries
    /// them instead of trusting a cache row the platform doesn't have.
    @discardableResult
    private func rollbackUnwrittenWrites(
        spotifyWrites: [QueuedSpotifyWrite],
        unwrittenSpotifyURIs: Set<String>,
        appleMusicWrites: [QueuedAppleMusicWrite],
        unwrittenAppleSongIds: Set<String>,
        context: ModelContext
    ) -> Int {
        var rolledBack = 0
        
        for write in spotifyWrites where unwrittenSpotifyURIs.contains(write.uri) {
            write.track.syncState = .pending
            write.track.spotifyTrackUri = nil
            write.track.source = write.originalSource
            write.track.unmatchedPlatform = nil
            rolledBack += 1
        }
        
        for write in appleMusicWrites where unwrittenAppleSongIds.contains(write.songId) {
            write.track.syncState = .pending
            write.track.appleMusicTrackId = nil
            write.track.source = write.originalSource
            write.track.unmatchedPlatform = nil
            rolledBack += 1
        }
        
        if rolledBack > 0 {
            print("[SyncEngine] Rolled back \(rolledBack) unwritten tracks to .pending")
            try? context.save()
        }
        
        return rolledBack
    }
    
    // MARK: - Applying a Plan
    
    private enum PlannedStep {
        /// Queue a write for this match, exactly as Stage B would.
        case write(MatchCandidate)
        /// Nothing to write; the row's state is final for this run.
        case settled(failed: Bool)
    }
    
    /// Applies the plan's decision for one pending row.
    private func applyDecision(to track: CachedTrack, run: RunContext) -> PlannedStep {
        guard let key = track.planKey(seamSource: run.seamSource), let decision = run.decisions[key] else {
            // Appeared after the preview: wait for the next one.
            track.syncState = .pending
            return .settled(failed: false)
        }
        switch decision {
        case .add(let match):
            return .write(match)
        case .review(let best, let alternatives):
            track.syncState = .needsReview
            track.candidates = [best] + alternatives
            recordEvidence(best, on: track)
            return .settled(failed: false)
        case .unavailable(let alternatives):
            track.syncState = .failed
            track.unmatchedPlatform = key.platform == .spotify ? .appleMusic : .spotify
            track.unavailableReason = .notInCatalog
            track.candidates = alternatives
            track.retryCount += 1
            return .settled(failed: true)
        case .alreadyPresent(let match):
            if match.track.platform == .appleMusic {
                track.appleMusicTrackId = match.track.id
            } else {
                track.spotifyTrackUri = match.track.id
            }
            track.source = .both
            track.syncState = .synced
            track.unmatchedPlatform = nil
            recordEvidence(match, on: track)
            return .settled(failed: false)
        }
    }
    
    private func recordEvidence(_ match: MatchCandidate?, on track: CachedTrack) {
        guard let match else { return }
        track.adoptArtwork(from: match.track)
        track.matchConfidence = match.confidence
        track.matchReason = match.reason
        track.counterpartISRC = match.track.isrc
    }
    
    /// Resolves the Apple Music songs a plan chose, by catalog ID, 25 per request.
    private func resolvePlannedSongs(_ run: RunContext) async -> [String: Song] {
        let ids: [String] = run.decisions.values.compactMap {
            if case .add(let match) = $0, match.track.platform == .appleMusic { return match.track.id }
            return nil
        }
        var songs: [String: Song] = [:]
        for batch in ids.chunked(into: 25) {
            do {
                let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
                for song in try await request.response().items {
                    songs[song.id.rawValue] = song
                }
            } catch {
                print("[SyncEngine] Planned song resolve failed: \(error.localizedDescription)")
            }
        }
        return songs
    }
    
    /// Removes the tracks a plan mirrored, if Stage A still flags them now.
    /// Apple Music removals only appear here when the seam's playlist was
    /// created by Antiphon (D1); others were planned as guided.
    /// Returns the cache rows whose tracks are gone from both playlists.
    /// Moves this run's additions next to their neighbours on the other
    /// side. Best effort: if it fails, they stay at the end where they landed.
    /// With "Same order", the target follows the source's whole order instead.
    private func placeAddedTracks(pair: SyncPair, cachedTracks: [CachedTrack], run: RunContext) async {
        let rows = cachedTracks.map(PlacementStep.Row.init)
        let editor = LivePlaylistEditor(spotifyClient: spotifyClient, appleMusicManager: appleMusicManager)
        if let target = pair.mirrorTarget {
            let (playlistId, otherId) = target == .spotify
                ? (pair.spotifyPlaylistId, pair.appleMusicPlaylistId)
                : (pair.appleMusicPlaylistId, pair.spotifyPlaylistId)
            do {
                let moved = try await PlacementStep.mirror(on: target, playlistId: playlistId, otherPlaylistId: otherId,
                                                           rows: rows, editor: editor)
                run.recordMoves(moved, on: target)
                if !moved.isEmpty { print("[SyncEngine] Reordered \(target.rawValue) to follow the source") }
            } catch {
                print("[SyncEngine] Reordering \(target.rawValue) failed; order unchanged: \(error)")
            }
            return
        }
        for (platform, keys) in run.addedRows where pair.canPlace(on: platform) {
            let (playlistId, otherId) = platform == .spotify
                ? (pair.spotifyPlaylistId, pair.appleMusicPlaylistId)
                : (pair.appleMusicPlaylistId, pair.spotifyPlaylistId)
            do {
                let moved = try await PlacementStep.place(keys, on: platform, playlistId: playlistId, otherPlaylistId: otherId,
                                                          rows: rows, editor: editor)
                run.recordMoves(moved, on: platform)
                if !moved.isEmpty { print("[SyncEngine] Placed \(keys.count) added tracks on \(platform.rawValue)") }
            } catch {
                print("[SyncEngine] Placing on \(platform.rawValue) failed; tracks stay at the end: \(error)")
            }
        }
    }

    private func applyPlannedRemovals(
        _ plan: SyncPlan,
        pair: SyncPair,
        amPlaylist: Playlist,
        cachedTracks: [CachedTrack],
        run: RunContext
    ) async throws -> [CachedTrack] {
        let stillFlagged = cachedTracks.filter { $0.removalFlag != nil && $0.removalKeptAt == nil }
        var removedRows: [CachedTrack] = []
        
        for platform in [Platform.spotify, .appleMusic] {
            let planned = plan.side(platform).removals.filter { !$0.isGuided }
            guard !planned.isEmpty else { continue }
            let rowsById = Dictionary(
                stillFlagged.compactMap { row in
                    (platform == .spotify ? row.spotifyTrackUri : row.appleMusicTrackId).map { ($0, row) }
                },
                uniquingKeysWith: { first, _ in first }
            )
            let removals = planned.filter { rowsById[$0.track.id] != nil }
            guard !removals.isEmpty else { continue }
            
            if platform == .spotify {
                try await spotifyClient.removeTracksFromPlaylist(
                    playlistId: pair.spotifyPlaylistId,
                    trackUris: removals.map(\.track.id)
                )
            } else {
                try await appleMusicManager.removeTracks(removals.map(\.track), from: amPlaylist)
            }
            for removal in removals {
                run.changes.append(SyncChange(platform: platform, kind: .remove, track: removal.track))
            }
            run.removedCount += removals.count
            removedRows += removals.compactMap { rowsById[$0.track.id] }
        }
        return removedRows
    }
    
    // MARK: - Interruption Handling
    
    private func handleInterruption(
        pair: SyncPair,
        context: ModelContext,
        action: SyncAction,
        tracksAdded: Int,
        tracksFailed: Int,
        cachedTracks: [CachedTrack],
        run: RunContext
    ) -> SyncResult {
        pair.lastInterruptedAt = Date()
        pair.lastSyncResult = .partial
        pair.lastSyncMessage = "Sync interrupted — will resume"
        
        // Reset any .syncing tracks back to .pending
        for track in cachedTracks where track.syncState == .syncing {
            track.syncState = .pending
        }
        
        try? context.save()
        
        logSync(pair: pair, context: context, action: action, run: run,
               result: .partial,
               tracksAdded: tracksAdded, tracksRemoved: 0,
               tracksFailed: tracksFailed, tracksMatched: cachedTracks.count,
               details: "Sync interrupted, \(tracksAdded) added so far")
        
        return SyncResult(
            pairId: pair.id,
            status: .partial,
            message: "Sync interrupted — will resume on next sync",
            tracksAdded: tracksAdded,
            tracksFailed: tracksFailed
        )
    }
    
    // MARK: - Helpers
    
    private func logSync(
        pair: SyncPair,
        context: ModelContext,
        action: SyncAction,
        run: RunContext,
        result: SyncResultStatus = .success,
        tracksAdded: Int,
        tracksRemoved: Int,
        tracksFailed: Int,
        tracksMatched: Int,
        details: String?
    ) {
        writeLog(pair: pair, context: context, action: action, trigger: run.trigger, startedAt: run.startedAt,
                 changes: run.takeChanges(), result: result, tracksAdded: tracksAdded, tracksRemoved: tracksRemoved,
                 tracksFailed: tracksFailed, tracksMatched: tracksMatched, details: details)
    }

    /// One History entry with the changes that landed, in order.
    private func writeLog(
        pair: SyncPair, context: ModelContext, action: SyncAction, trigger: SyncTrigger, startedAt: Date,
        changes: [SyncChange], result: SyncResultStatus, tracksAdded: Int, tracksRemoved: Int,
        tracksFailed: Int, tracksMatched: Int, details: String?
    ) {
        let log = SyncLog(
            action: action,
            result: result,
            tracksAdded: tracksAdded,
            tracksRemoved: tracksRemoved,
            tracksFailed: tracksFailed,
            tracksMatched: tracksMatched,
            details: details
        )
        log.syncPair = pair
        log.trigger = trigger
        log.startedAt = startedAt
        log.duration = Date().timeIntervalSince(startedAt)
        context.insert(log)
        for (index, change) in changes.enumerated() {
            change.sequence = index
            change.run = log
            context.insert(change)
        }
    }
    
    private func buildSyncMessage(flagged: Int, unmatched: Int, review: Int, total: Int) -> String {
        if total == 0 {
            return "No tracks in playlist"
        }
        let synced = total - flagged - unmatched - review
        
        if unmatched == 0 && flagged == 0 && review == 0 {
            return "All \(total) tracks in sync"
        }
        
        var parts: [String] = []
        if flagged > 0 {
            parts.append("\(flagged) flagged")
        }
        if review > 0 {
            parts.append("\(review) to review")
        }
        if unmatched > 0 {
            parts.append("\(unmatched) missing")
        }
        if synced > 0 {
            parts.append("\(synced) synced")
        }
        
        return parts.joined(separator: ", ")
    }
}

// MARK: - Sync Errors

enum SyncError: LocalizedError {
    case appleMusicPlaylistNotFound
    case spotifyPlaylistNotFound
    case syncAlreadyInProgress
    case safetyThresholdExceeded(Int)
    
    var errorDescription: String? {
        switch self {
        case .appleMusicPlaylistNotFound:
            return "The linked Apple Music playlist could not be found."
        case .spotifyPlaylistNotFound:
            return "The linked Spotify playlist could not be found."
        case .syncAlreadyInProgress:
            return "A sync operation is already in progress."
        case .safetyThresholdExceeded(let percentage):
            return "Safety threshold exceeded: \(percentage)% of tracks would be removed."
        }
    }
}

// MARK: - Run Context

/// Per-run state: what started the run, the plan being applied (if any),
/// and the changes that landed. Lives only inside one `syncSinglePair` call.
private final class RunContext {
    let trigger: SyncTrigger
    let startedAt = Date()
    let planned: PlannedSync
    let decisions: [TrackKey: PlannedDecision]
    /// Set once Stage A decides which side is the source.
    var seamSource: Platform
    var changes: [SyncChange] = []
    var removedCount = 0
    /// Rows added this run, by the platform they landed on, for placing.
    var addedRows: [Platform: Set<String>] = [:]

    init(trigger: SyncTrigger, planned: PlannedSync, approved: Set<TrackKey> = []) {
        self.trigger = trigger
        self.planned = planned
        self.decisions = planned.plan.decisions(approving: approved)
        self.seamSource = planned.sourcePlatform
    }

    func recordAdd(of track: CachedTrack, on platform: Platform, id: String) {
        let landed = CatalogTrack(
            platform: platform, id: id, title: track.title, artist: track.artist, album: track.albumName,
            durationMs: track.durationMs, isrc: track.counterpartISRC ?? (track.isrc.hasPrefix("local-") ? nil : track.isrc),
            artworkURL: track.artworkURL
        )
        changes.append(SyncChange(platform: platform, kind: .add, track: landed,
                                  confidence: track.matchConfidence, reason: track.matchReason))
        addedRows[platform, default: []].insert(track.id.uuidString)
    }

    /// The changes recorded so far, handed to the log once.
    func takeChanges() -> [SyncChange] {
        defer { changes = [] }
        return changes
    }

    /// Reorders are logged per moved track, so undo can put them back.
    func recordMoves(_ moved: [PlacementStep.Moved], on platform: Platform) {
        for move in moved {
            changes.append(SyncChange(platform: platform, kind: .move, track: move.track,
                                      fromIndex: move.from, toIndex: move.to))
        }
    }
}

extension SyncTrigger {
    /// The trigger implied by a legacy `SyncAction`.
    init(_ action: SyncAction) {
        switch action {
        case .initialSync: self = .firstSync
        case .monitorSync: self = .monitor
        case .manualSync, .deltaSync, .fullRebuild: self = .manual
        }
    }
}
