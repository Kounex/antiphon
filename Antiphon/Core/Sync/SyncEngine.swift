import Foundation
import SwiftData
import MusicKit

/// Progress callback type — called after each track is processed.
typealias SyncProgressCallback = @Sendable (SyncProgress) async -> Void

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
    
    private var lastSyncTimestamp: Date?
    
    init(
        modelContainer: ModelContainer,
        spotifyClient: SpotifyAPIClient,
        appleMusicManager: AppleMusicManager
    ) {
        self.modelContainer = modelContainer
        self.spotifyClient = spotifyClient
        self.appleMusicManager = appleMusicManager
        self.trackMatcher = TrackMatcher(
            spotifyClient: spotifyClient,
            appleMusicManager: appleMusicManager
        )
    }
    
    // MARK: - Public API
    
    /// Performs a delta sync for all monitored SyncPairs.
    /// Called by foreground sync, AppIntent, and BGAppRefreshTask.
    @discardableResult
    func syncAllMonitored() async -> [SyncResult] {
        let context = ModelContext(modelContainer)
        
        let descriptor = FetchDescriptor<SyncPair>(
            predicate: #Predicate { $0.isMonitored == true }
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
            
            // Skip pairs synced recently (per-pair cooldown)
            if let lastSync = pair.lastSyncedAt,
               Date().timeIntervalSince(lastSync) < AppConstants.Sync.minimumSyncIntervalSeconds {
                continue
            }
            
            let result = await syncSinglePair(pair, context: context, action: .monitorSync)
            results.append(result)
        }
        
        try? context.save()
        lastSyncTimestamp = Date()
        
        return results
    }
    
    /// Performs a sync for a specific SyncPair.
    /// Accepts an optional progress callback for real-time UI updates.
    @discardableResult
    func syncPair(
        _ pairId: UUID,
        action: SyncAction = .manualSync,
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
            progressCallback: progressCallback
        )
        try? context.save()
        
        return result
    }
    
    /// Forces a complete sync (ignoring the cache) for a SyncPair.
    /// Used for initial sync and "Force Full Rebuild".
    @discardableResult
    func fullSync(_ pairId: UUID) async -> SyncResult {
        return await syncPair(pairId, action: .initialSync)
    }
    
    /// Whether enough time has passed since the last sync to justify another one.
    var shouldSync: Bool {
        guard let last = lastSyncTimestamp else { return true }
        return Date().timeIntervalSince(last) >= AppConstants.Sync.minimumSyncIntervalSeconds
    }
    
    // MARK: - Core Sync Algorithm
    
    private func syncSinglePair(
        _ pair: SyncPair,
        context: ModelContext,
        action: SyncAction,
        progressCallback: SyncProgressCallback? = nil
    ) async -> SyncResult {
        
        pair.lastSyncResult = .inProgress
        pair.lastSyncMessage = nil
        
        var tracksAdded = 0
        var tracksFailed = 0
        
        // ── Fetch local database cache (Exactly 1 query for the entire sync run) ──
        let pairId = pair.id
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
            
            let isResume = pair.lastInterruptedAt != nil
                && !cachedTracks.isEmpty
                && cachedTracks.contains(where: { $0.syncState == .pending || $0.syncState == .syncing })
            
            if isResume {
                // Resume: skip Stage A, go directly to Stage B with pending tracks
                print("[SyncEngine] Resuming interrupted sync for \(pair.spotifyPlaylistName)")
                pair.lastInterruptedAt = nil
                
                // Reset any tracks stuck in .syncing back to .pending
                for track in cachedTracks where track.syncState == .syncing {
                    track.syncState = .pending
                }
                try? context.save()
                
                let pendingTracks = cachedTracks.filter { $0.syncState == .pending }
                let totalTracks = cachedTracks.count
                let alreadyCompleted = totalTracks - pendingTracks.count
                
                // Report progress immediately for resume
                await progressCallback?(SyncProgress(
                    totalTracks: totalTracks,
                    completedTracks: alreadyCompleted,
                    failedTracks: 0,
                    currentTrackName: "Preparing resume..."
                ))
                
                // Find the target playlist for matching
                let amPlaylists = try await appleMusicManager.fetchUserPlaylists()
                let amPlaylist = amPlaylists.first(where: { $0.id.rawValue == pair.appleMusicPlaylistId })
                
                // Fetch current tracks from both to prevent duplicates during resume
                let spotifyTracks = try await spotifyClient.getPlaylistTracks(
                    playlistId: pair.spotifyPlaylistId
                )
                let appleMusicTracks: [AppleMusicTrackInfo]
                if let amPlaylist = amPlaylist {
                    appleMusicTracks = try await appleMusicManager.fetchPlaylistTracks(
                        for: amPlaylist,
                        localISRCLookup: localISRCLookup
                    )
                } else {
                    appleMusicTracks = []
                }
                
                let matchResult = await matchTracksOneByOne(
                    pendingTracks: pendingTracks,
                    pair: pair,
                    context: context,
                    amPlaylist: amPlaylist,
                    spotifyTracks: spotifyTracks,
                    appleMusicTracks: appleMusicTracks,
                    action: action,
                    totalTracks: totalTracks,
                    alreadyCompleted: alreadyCompleted,
                    progressCallback: progressCallback
                )
                
                tracksAdded = matchResult.added
                tracksFailed = matchResult.failed
                
                // Check if we were cancelled again
                if Task.isCancelled {
                    return handleInterruption(pair: pair, context: context, action: action,
                                            tracksAdded: tracksAdded, tracksFailed: tracksFailed,
                                            cachedTracks: cachedTracks)
                }
                
            } else {
                // Full sync: Stage A + Stage B
                
                // ── Step 0: Create pending playlists if needed ──
                
                if pair.appleMusicPlaylistId.hasPrefix("pending-creation-") {
                    let newPlaylist = try await appleMusicManager.createPlaylist(
                        name: pair.appleMusicPlaylistName,
                        description: "Synced from Spotify by Antiphon"
                    )
                    pair.appleMusicPlaylistId = newPlaylist.id.rawValue
                }
                
                if pair.spotifyPlaylistId.hasPrefix("pending-creation-") {
                    let user = try await spotifyClient.getCurrentUser()
                    let newPlaylist = try await spotifyClient.createPlaylist(
                        userId: user.id,
                        name: pair.spotifyPlaylistName,
                        description: "Synced from Apple Music by Antiphon"
                    )
                    pair.spotifyPlaylistId = newPlaylist.id
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
                
                // Determine isSpotifySource dynamically for bidirectional initial sync
                let isSpotifySource: Bool
                if pair.syncDirection == .bidirectional {
                    if spotifyTracks.isEmpty && !appleMusicTracks.isEmpty {
                        isSpotifySource = false
                    } else {
                        // Default to Spotify if Spotify has tracks, or if both are empty/non-empty
                        isSpotifySource = true
                    }
                } else {
                    isSpotifySource = pair.syncDirection != .appleToSpotify
                }
                
                // ── Step 2: Populate cache with source tracks immediately ──
                let isInitialSync = action == .initialSync || action == .fullRebuild || cachedTracks.isEmpty
                
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
                if isInitialSync {
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
                if !isInitialSync && !cachedTracks.isEmpty {
                    let totalRemovals = cachedTracks.filter { $0.removalFlag == .removedFromSpotify || $0.removalFlag == .removedFromAppleMusic || $0.removalFlag == .removedFromSource }.count
                    let removalPercentage = Double(totalRemovals) / Double(cachedTracks.count)
                    
                    if removalPercentage > AppConstants.Sync.safetyThresholdPercentage {
                        let message = "Safety threshold triggered: \(totalRemovals) tracks would be removed (\(Int(removalPercentage * 100))%). Sync aborted."
                        pair.lastSyncResult = .failed
                        pair.lastSyncMessage = message
                        logSync(pair: pair, context: context, action: action,
                               tracksAdded: 0, tracksRemoved: 0, tracksFailed: 0,
                               tracksMatched: cachedTracks.count, details: message)
                        return SyncResult(pairId: pair.id, status: .failed, message: message)
                    }
                }
                
                // ══════════════════════════════════════════════════
                // ── STAGE B: Match tracks one-by-one ──
                // ══════════════════════════════════════════════════
                
                let pendingTracks = cachedTracks.filter { $0.syncState == .pending || ($0.syncState == .failed && $0.retryCount < 3) }
                let totalTracks = cachedTracks.count
                let alreadyCompleted = totalTracks - pendingTracks.count
                
                // Report initial progress
                await progressCallback?(SyncProgress(
                    totalTracks: totalTracks,
                    completedTracks: alreadyCompleted,
                    failedTracks: 0,
                    currentTrackName: nil
                ))
                
                let matchResult = await matchTracksOneByOne(
                    pendingTracks: pendingTracks,
                    pair: pair,
                    context: context,
                    amPlaylist: amPlaylist,
                    spotifyTracks: spotifyTracks,
                    appleMusicTracks: appleMusicTracks,
                    action: action,
                    totalTracks: totalTracks,
                    alreadyCompleted: alreadyCompleted,
                    progressCallback: progressCallback
                )
                
                tracksAdded = matchResult.added
                tracksFailed = matchResult.failed
                
                // Check if we were cancelled
                if Task.isCancelled {
                    return handleInterruption(pair: pair, context: context, action: action,
                                            tracksAdded: tracksAdded, tracksFailed: tracksFailed,
                                            cachedTracks: cachedTracks)
                }
            }
            
            // ── Final: Log result ──
            let totalRemovalFlags = cachedTracks.filter { $0.removalFlag != nil }.count
            let totalUnmatched = cachedTracks.filter { $0.unmatchedPlatform != nil || $0.effectiveSyncState == .failed }.count
            let totalMatched = cachedTracks.count
            let resultStatus: SyncResultStatus = totalUnmatched > 0 ? .failed : (totalRemovalFlags > 0 ? .partial : .success)
            
            let message = buildSyncMessage(
                flagged: totalRemovalFlags,
                unmatched: totalUnmatched,
                total: totalMatched
            )
            
            pair.lastSyncedAt = Date()
            pair.lastSyncResult = resultStatus
            pair.lastSyncMessage = message
            pair.lastInterruptedAt = nil
            
            logSync(
                pair: pair, context: context, action: action,
                tracksAdded: tracksAdded, tracksRemoved: totalRemovalFlags,
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
            
        } catch {
            let message = "Sync failed: \(error.localizedDescription)"
            pair.lastSyncResult = .failed
            pair.lastSyncMessage = message
            
            logSync(pair: pair, context: context, action: action,
                   tracksAdded: tracksAdded, tracksRemoved: 0,
                   tracksFailed: tracksFailed, tracksMatched: 0,
                   details: message)
            
            return SyncResult(pairId: pair.id, status: .failed, message: message)
        }
    }
    
    // MARK: - Per-Track Matching (Stage B)
    
    private struct MatchResult {
        var added: Int
        var failed: Int
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
        progressCallback: SyncProgressCallback?
    ) async -> MatchResult {
        var added = 0
        var failed = 0
        var completed = alreadyCompleted
        
        // Batch URIs for Spotify additions
        var spotifyUrisToAdd: [String] = []
        
        // Batch songs for Apple Music additions
        var appleMusicSongsToAdd: [Song] = []
        
        // Pre-resolve Apple Music catalog songs by ISRC in batches to avoid sequential network requests
        var resolvedSongsByISRC: [String: Song] = [:]
        let appleMatchTracks = pendingTracks.filter { $0.source == .spotify && pair.syncDirection != .appleToSpotify }
        let isrcsToResolve = appleMatchTracks.map { $0.isrc }.filter { !$0.isEmpty && !$0.hasPrefix("local-") }
        
        if !isrcsToResolve.isEmpty {
            let batches = isrcsToResolve.chunked(into: 25)
            for batch in batches {
                do {
                    let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, memberOf: batch)
                    let response = try await request.response()
                    for song in response.items {
                        if let isrc = song.isrc {
                            resolvedSongsByISRC[isrc.lowercased()] = song
                        }
                    }
                } catch {
                    print("[SyncEngine] Batch ISRC resolve failed for Stage B: \(error.localizedDescription)")
                }
            }
        }
        
        for track in pendingTracks {
            // Cancellation checkpoint
            if Task.isCancelled {
                break
            }
            
            // Mark as syncing
            track.syncState = .syncing
            track.lastSyncAttempt = Date()
            
            // Report progress
            await progressCallback?(SyncProgress(
                totalTracks: totalTracks,
                completedTracks: completed,
                failedTracks: failed,
                currentTrackName: track.title
            ))
            
            do {
                // Determine which direction to match
                let needsAppleMatch = track.source == .spotify && pair.syncDirection != .appleToSpotify
                let needsSpotifyMatch = track.source == .appleMusic && pair.syncDirection != .spotifyToApple
                
                if needsAppleMatch {
                    // Try pre-resolved song first
                    var song: Song? = resolvedSongsByISRC[track.isrc.lowercased()]
                    
                    if song == nil {
                        // Find on Apple Music Catalog (exact isrc then fuzzy fallback)
                        song = try await trackMatcher.findAppleMusicTrack(
                            forISRC: track.isrc,
                            title: track.title,
                            artist: track.artist,
                            durationMs: track.durationMs
                        )
                    }
                    
                    if let song {
                        // Check if already in target playlist
                        let alreadyExists = appleMusicTracks.contains { appleTrack in
                            trackMatcher.isMatch(song: song, appleTrack: appleTrack)
                        }
                        
                        if !alreadyExists {
                            appleMusicSongsToAdd.append(song)
                            added += 1
                        } else {
                            print("[SyncEngine] Track '\(track.title)' already exists in Apple Music target playlist. Skipping add.")
                        }
                        
                        track.appleMusicTrackId = song.id.rawValue
                        track.syncState = .synced
                        track.source = .both
                        track.unmatchedPlatform = nil
                    } else {
                        track.syncState = .failed
                        track.unmatchedPlatform = .appleMusic
                        track.retryCount += 1
                        failed += 1
                    }
                } else if needsSpotifyMatch {
                    // Find on Spotify
                    if let spotifyTrack = try await trackMatcher.findSpotifyTrack(
                        forISRC: track.isrc,
                        title: track.title,
                        artist: track.artist,
                        durationMs: track.durationMs
                    ) {
                        // Check if already in target playlist
                        let alreadyExists = spotifyTracks.contains { spotifyItem in
                            trackMatcher.isMatch(spotifyTrack: spotifyTrack, spotifyItem: spotifyItem)
                        }
                        
                        if !alreadyExists {
                            spotifyUrisToAdd.append(spotifyTrack.uri)
                            added += 1
                        } else {
                            print("[SyncEngine] Track '\(track.title)' already exists in Spotify target playlist. Skipping add.")
                        }
                        
                        track.spotifyTrackUri = spotifyTrack.uri
                        track.syncState = .synced
                        track.source = .both
                        track.unmatchedPlatform = nil
                    } else {
                        track.syncState = .failed
                        track.unmatchedPlatform = .spotify
                        track.retryCount += 1
                        failed += 1
                    }
                } else {
                    // No matching needed (direction doesn't require it)
                    track.syncState = .skipped
                }
                
            } catch {
                // Network/API error for this track — mark as failed, continue with others
                print("[SyncEngine] Track match error for '\(track.title)': \(error.localizedDescription)")
                track.syncState = .failed
                track.retryCount += 1
                failed += 1
            }
            
            completed += 1
            
            // Save after each track for live UI updates and crash resilience
            try? context.save()
        }
        
        // Batch-add Spotify tracks if any
        if !spotifyUrisToAdd.isEmpty && !Task.isCancelled {
            do {
                try await spotifyClient.addTracksToPlaylist(
                    playlistId: pair.spotifyPlaylistId,
                    trackUris: spotifyUrisToAdd
                )
            } catch {
                print("[SyncEngine] Failed to batch-add Spotify tracks: \(error.localizedDescription)")
            }
        }
        
        // Batch-add Apple Music tracks if any
        if !appleMusicSongsToAdd.isEmpty && !Task.isCancelled {
            do {
                if let amPlaylist = amPlaylist {
                    try await appleMusicManager.addTracks(appleMusicSongsToAdd, to: amPlaylist)
                }
            } catch {
                print("[SyncEngine] Failed to batch-add Apple Music tracks: \(error.localizedDescription)")
            }
        }
        
        return MatchResult(added: added, failed: failed)
    }
    
    // MARK: - Interruption Handling
    
    private func handleInterruption(
        pair: SyncPair,
        context: ModelContext,
        action: SyncAction,
        tracksAdded: Int,
        tracksFailed: Int,
        cachedTracks: [CachedTrack]
    ) -> SyncResult {
        pair.lastInterruptedAt = Date()
        pair.lastSyncResult = .partial
        pair.lastSyncMessage = "Sync interrupted — will resume"
        
        // Reset any .syncing tracks back to .pending
        for track in cachedTracks where track.syncState == .syncing {
            track.syncState = .pending
        }
        
        try? context.save()
        
        logSync(pair: pair, context: context, action: action,
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
    
    // MARK: - Background Refresh Handler
    
    /// Handles a BGAppRefreshTask. Called from the background task handler.
    func handleBackgroundRefresh() async -> Bool {
        guard shouldSync else { return true }
        let results = await syncAllMonitored()
        return results.allSatisfy { $0.status != .failed }
    }
    
    // MARK: - Helpers
    
    private func logSync(
        pair: SyncPair,
        context: ModelContext,
        action: SyncAction,
        tracksAdded: Int,
        tracksRemoved: Int,
        tracksFailed: Int,
        tracksMatched: Int,
        details: String?
    ) {
        let log = SyncLog(
            action: action,
            tracksAdded: tracksAdded,
            tracksRemoved: tracksRemoved,
            tracksFailed: tracksFailed,
            tracksMatched: tracksMatched,
            details: details
        )
        log.syncPair = pair
        context.insert(log)
    }
    
    private func buildSyncMessage(flagged: Int, unmatched: Int, total: Int) -> String {
        if total == 0 {
            return "No tracks in playlist"
        }
        let synced = total - flagged - unmatched
        
        if unmatched == 0 && flagged == 0 {
            return "All \(total) tracks in sync"
        }
        
        var parts: [String] = []
        if flagged > 0 {
            parts.append("\(flagged) flagged")
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
