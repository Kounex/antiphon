import Foundation
import SwiftData

/// Computes differences and matches target remote tracks with cached tracks using O(1) dictionary lookups.
struct DeltaEngine {

    /// How long a track Antiphon added may be missing from Apple Music's
    /// playlist reads before it counts as removed.
    static let appleMusicReadGrace: TimeInterval = 15 * 60

    /// The row's track was on `platform` and isn't any more.
    ///
    /// Besides rows on both sides, this catches rows an earlier version left
    /// one-sided without a question (it cleared the flag on the next sync),
    /// so their removal is asked about again instead of passing as in sync.
    ///
    /// Apple Music lists a track in playlist reads some time after it was
    /// added. A row that still carries the catalog ID it was added with has
    /// never been seen there, so it isn't called removed until
    /// `appleMusicReadGrace` after the write.
    static func isRemoved(_ cached: CachedTrack, from platform: Platform, live: Set<String>, now: Date = Date()) -> Bool {
        let id = platform == .spotify ? cached.spotifyTrackUri : cached.appleMusicTrackId
        guard let id, !live.contains(id) else { return false }
        if platform == .appleMusic, !id.hasPrefix("i."), let written = cached.lastSyncAttempt,
           now.timeIntervalSince(written) < appleMusicReadGrace {
            return false
        }
        if cached.source == .both { return true }
        let otherSide: TrackSource = platform == .spotify ? .appleMusic : .spotify
        return cached.source == otherSide && cached.removalFlag == nil && cached.removalKeptAt == nil
    }
    
    /// Points cached rows whose `appleMusicTrackId` is not among the live
    /// playlist IDs back at the live library track they correspond to.
    ///
    /// Stage B and manual matching store catalog Song IDs, but playlist reads
    /// return library-track IDs, so without this every such row would look
    /// removed from Apple Music on the next sync. Matches by ISRC first, then
    /// by fuzzy title/artist/duration, and never claims a live track that
    /// another row already owns. Rows with no match are left untouched so
    /// genuine removals are still detected.
    static func reanchorAppleMusicIds(
        cachedTracks: [CachedTrack],
        appleMusicTracks: [AppleMusicTrackInfo],
        trackMatcher: TrackMatcher
    ) {
        let liveAppleIDs = Set(appleMusicTracks.map(\.id))
        let staleTracks = cachedTracks.filter { cached in
            guard let id = cached.appleMusicTrackId else { return false }
            return !liveAppleIDs.contains(id)
        }
        guard !staleTracks.isEmpty else { return }
        
        var claimedIDs = Set(cachedTracks.compactMap(\.appleMusicTrackId)).intersection(liveAppleIDs)
        let normalizedAppleTracks = appleMusicTracks.map {
            (id: $0.id, isrc: $0.isrc?.lowercased(), title: $0.title.normalizedForMatching,
             artist: $0.artist.normalizedForMatching, durationMs: $0.durationMs)
        }
        
        for cached in staleTracks {
            let cachedIsrc = cached.isrc.lowercased()
            let hasRealIsrc = !cachedIsrc.isEmpty && !cachedIsrc.hasPrefix("local-")
            let unclaimed = normalizedAppleTracks.filter { !claimedIDs.contains($0.id) }
            
            var match = hasRealIsrc ? unclaimed.first { $0.isrc == cachedIsrc } : nil
            if match == nil {
                let targetTitle = cached.title.normalizedForMatching
                let targetArtist = cached.artist.normalizedForMatching
                match = unclaimed.first { candidate in
                    trackMatcher.matchScore(
                        candidateTitle: candidate.title,
                        candidateArtist: candidate.artist,
                        candidateDurationMs: candidate.durationMs,
                        targetTitle: targetTitle,
                        targetArtist: targetArtist,
                        targetDurationMs: cached.durationMs
                    ) >= 0.75
                }
            }
            
            if let match {
                cached.appleMusicTrackId = match.id
                claimedIDs.insert(match.id)
            }
        }
    }
    
    /// Matches cache tracks with target tracks and updates sync state.
    /// Returns the updated list of cached tracks.
    static func matchTargetTracks(
        in context: ModelContext,
        pair: SyncPair,
        cachedTracks: [CachedTrack],
        spotifyTracks: [SpotifyPlaylistItem],
        appleMusicTracks: [AppleMusicTrackInfo],
        isInitialSync: Bool,
        isSpotifySource: Bool,
        trackMatcher: TrackMatcher,
        persist: Bool = true
    ) -> [CachedTrack] {
        
        if isSpotifySource {
            // Spotify is source, Apple Music is target
            
            // Precompute normalized strings once per target track — the fuzzy
            // pass below is O(N×M) and must not re-normalize per comparison
            let normalizedAppleTracks: [(id: String, title: String, artist: String, durationMs: Int?)] =
                appleMusicTracks.map {
                    ($0.id, $0.title.normalizedForMatching, $0.artist.normalizedForMatching, $0.durationMs)
                }
            
            // Map target Apple Music tracks by ISRC for O(1) matching in Pass 1
            var targetByISRC: [String: AppleMusicTrackInfo] = [:]
            for appleTrack in appleMusicTracks {
                if let isrc = appleTrack.isrc, !isrc.isEmpty {
                    targetByISRC[isrc.lowercased()] = appleTrack
                }
            }
            
            var matchedAppleTrackIds = Set<String>()
            
            // Pass 1: Match by exact ISRC (O(N))
            for cached in cachedTracks {
                // Skip source removals — CacheAligner flagged them for user review
                // moments earlier and matching here would clear that flag
                guard cached.source == .spotify, cached.removalFlag != .removedFromSource else { continue }
                let lowercasedIsrc = cached.isrc.lowercased()
                if let appleTrack = targetByISRC[lowercasedIsrc] {
                    cached.source = .both
                    cached.appleMusicTrackId = appleTrack.id
                    cached.syncState = .synced
                    cached.removalFlag = nil
                    cached.removalFlaggedAt = nil
                    matchedAppleTrackIds.insert(appleTrack.id)
                }
            }
            
            // Pass 2: Match by fuzzy (title/artist/duration)
            for cached in cachedTracks {
                guard cached.source == .spotify, cached.removalFlag != .removedFromSource else { continue }
                let targetTitle = cached.title.normalizedForMatching
                let targetArtist = cached.artist.normalizedForMatching
                let targetDuration = cached.durationMs
                
                if let match = normalizedAppleTracks.first(where: { candidate in
                    !matchedAppleTrackIds.contains(candidate.id) &&
                    trackMatcher.matchScore(
                        candidateTitle: candidate.title,
                        candidateArtist: candidate.artist,
                        candidateDurationMs: candidate.durationMs,
                        targetTitle: targetTitle,
                        targetArtist: targetArtist,
                        targetDurationMs: targetDuration
                    ) >= 0.75
                }) {
                    cached.source = .both
                    cached.appleMusicTrackId = match.id
                    cached.syncState = .synced
                    cached.removalFlag = nil
                    cached.removalFlaggedAt = nil
                    matchedAppleTrackIds.insert(match.id)
                }
            }
            
            // Destination-only tracks (on Apple Music but not in cached)
            let cachedAppleIds = Set(cachedTracks.compactMap { $0.appleMusicTrackId })
            let normalizedCachedTracks = cachedTracks.map {
                (isrc: $0.isrc.lowercased(), title: $0.title.normalizedForMatching, artist: $0.artist.normalizedForMatching, durationMs: $0.durationMs)
            }
            var nextAddedAt = (cachedTracks.map { $0.addedAt }.max() ?? Date()).addingTimeInterval(1.0)
            for appleTrack in appleMusicTracks {
                if !matchedAppleTrackIds.contains(appleTrack.id) && !cachedAppleIds.contains(appleTrack.id) {
                    let isrc = appleTrack.isrc ?? "local-\(appleTrack.id)"
                    
                    // Skip if this track (by ISRC or title/artist fuzzy match) is already in the cache
                    let candidateTitle = appleTrack.title.normalizedForMatching
                    let candidateArtist = appleTrack.artist.normalizedForMatching
                    let lowercasedIsrc = isrc.lowercased()
                    let alreadyCached = normalizedCachedTracks.contains { cached in
                        if !lowercasedIsrc.hasPrefix("local-") && !cached.isrc.hasPrefix("local-") {
                            return cached.isrc == lowercasedIsrc
                        }
                        return trackMatcher.matchScore(
                            candidateTitle: candidateTitle,
                            candidateArtist: candidateArtist,
                            candidateDurationMs: appleTrack.durationMs,
                            targetTitle: cached.title,
                            targetArtist: cached.artist,
                            targetDurationMs: cached.durationMs
                        ) >= 0.75
                    }
                    if alreadyCached { continue }
                    
                    let isBidirectional = pair.syncDirection == .bidirectional
                    let cached = CachedTrack(
                        isrc: isrc,
                        title: appleTrack.title,
                        artist: appleTrack.artist,
                        albumName: appleTrack.albumName,
                        artworkURL: appleTrack.artworkURL,
                        durationMs: appleTrack.durationMs,
                        spotifyTrackUri: nil,
                        appleMusicTrackId: appleTrack.id,
                        source: .appleMusic,
                        syncState: isBidirectional ? .pending : .synced
                    )
                    cached.addedAt = nextAddedAt
                    nextAddedAt = nextAddedAt.addingTimeInterval(1.0)
                    if !isBidirectional {
                        cached.removalFlag = .extraOnDestination
                        cached.removalFlaggedAt = Date()
                    }
                    cached.syncPair = pair
                    context.insert(cached)
                }
            }
            
            // Detect removals on target (Apple Music) for delta sync
            if !isInitialSync {
                let liveAppleIDs = Set(appleMusicTracks.map { $0.id })
                let appleRemoved = cachedTracks.filter { isRemoved($0, from: .appleMusic, live: liveAppleIDs) }
                for cached in appleRemoved {
                    cached.source = .spotify
                    cached.removalFlag = .removedFromAppleMusic
                    cached.removalFlaggedAt = Date()
                }
            }
            
        } else {
            // Apple Music is source, Spotify is target
            
            // Precompute normalized strings once per target track — the fuzzy
            // pass below is O(N×M) and must not re-normalize per comparison
            let normalizedSpotifyTracks: [(uri: String, title: String, artist: String, durationMs: Int?)] =
                spotifyTracks.compactMap { item in
                    guard let sTrack = item.track else { return nil }
                    return (sTrack.uri, sTrack.name.normalizedForMatching, sTrack.primaryArtist.normalizedForMatching, sTrack.durationMs)
                }
            
            // Map target Spotify tracks by ISRC for O(1) matching in Pass 1
            var targetByISRC: [String: SpotifyPlaylistItem] = [:]
            for item in spotifyTracks {
                guard let sTrack = item.track else { continue }
                if let isrc = sTrack.isrc, !isrc.isEmpty {
                    targetByISRC[isrc.lowercased()] = item
                }
            }
            
            var matchedSpotifyURIs = Set<String>()
            
            // Pass 1: Match by exact ISRC (O(N))
            for cached in cachedTracks {
                // Skip source removals — CacheAligner flagged them for user review
                // moments earlier and matching here would clear that flag
                guard cached.source == .appleMusic, cached.removalFlag != .removedFromSource else { continue }
                let lowercasedIsrc = cached.isrc.lowercased()
                if let spotifyItem = targetByISRC[lowercasedIsrc], let sTrack = spotifyItem.track {
                    cached.source = .both
                    cached.spotifyTrackUri = sTrack.uri
                    cached.adoptArtwork(url: sTrack.album?.images?.first?.url)
                    cached.syncState = .synced
                    cached.removalFlag = nil
                    cached.removalFlaggedAt = nil
                    matchedSpotifyURIs.insert(sTrack.uri)
                }
            }
            
            // Pass 2: Match by fuzzy (title/artist/duration)
            for cached in cachedTracks {
                guard cached.source == .appleMusic, cached.removalFlag != .removedFromSource else { continue }
                let targetTitle = cached.title.normalizedForMatching
                let targetArtist = cached.artist.normalizedForMatching
                let targetDuration = cached.durationMs
                
                if let match = normalizedSpotifyTracks.first(where: { candidate in
                    !matchedSpotifyURIs.contains(candidate.uri) &&
                    trackMatcher.matchScore(
                        candidateTitle: candidate.title,
                        candidateArtist: candidate.artist,
                        candidateDurationMs: candidate.durationMs,
                        targetTitle: targetTitle,
                        targetArtist: targetArtist,
                        targetDurationMs: targetDuration
                    ) >= 0.75
                }) {
                    cached.source = .both
                    cached.spotifyTrackUri = match.uri
                    cached.syncState = .synced
                    cached.removalFlag = nil
                    cached.removalFlaggedAt = nil
                    matchedSpotifyURIs.insert(match.uri)
                }
            }
            
            // Destination-only tracks (on Spotify but not in cached)
            let cachedSpotifyUris = Set(cachedTracks.compactMap { $0.spotifyTrackUri })
            let normalizedCachedTracks = cachedTracks.map {
                (isrc: $0.isrc.lowercased(), title: $0.title.normalizedForMatching, artist: $0.artist.normalizedForMatching, durationMs: $0.durationMs)
            }
            var nextAddedAt = (cachedTracks.map { $0.addedAt }.max() ?? Date()).addingTimeInterval(1.0)
            for item in spotifyTracks {
                guard let sTrack = item.track else { continue }
                if !matchedSpotifyURIs.contains(sTrack.uri) && !cachedSpotifyUris.contains(sTrack.uri) {
                    let isrc = sTrack.isrc ?? "local-\(sTrack.uri)"
                    
                    // Skip if this track (by ISRC or title/artist fuzzy match) is already in the cache
                    let candidateTitle = sTrack.name.normalizedForMatching
                    let candidateArtist = sTrack.primaryArtist.normalizedForMatching
                    let lowercasedIsrc = isrc.lowercased()
                    let alreadyCached = normalizedCachedTracks.contains { cached in
                        if !lowercasedIsrc.hasPrefix("local-") && !cached.isrc.hasPrefix("local-") {
                            return cached.isrc == lowercasedIsrc
                        }
                        return trackMatcher.matchScore(
                            candidateTitle: candidateTitle,
                            candidateArtist: candidateArtist,
                            candidateDurationMs: sTrack.durationMs,
                            targetTitle: cached.title,
                            targetArtist: cached.artist,
                            targetDurationMs: cached.durationMs
                        ) >= 0.75
                    }
                    if alreadyCached { continue }
                    
                    let isBidirectional = pair.syncDirection == .bidirectional
                    let cached = CachedTrack(
                        isrc: isrc,
                        title: sTrack.name,
                        artist: sTrack.primaryArtist,
                        albumName: sTrack.album?.name,
                        artworkURL: sTrack.album?.images?.first?.url,
                        durationMs: sTrack.durationMs,
                        spotifyTrackUri: sTrack.uri,
                        appleMusicTrackId: nil,
                        source: .spotify,
                        syncState: isBidirectional ? .pending : .synced
                    )
                    cached.addedAt = nextAddedAt
                    nextAddedAt = nextAddedAt.addingTimeInterval(1.0)
                    if !isBidirectional {
                        cached.removalFlag = .extraOnDestination
                        cached.removalFlaggedAt = Date()
                    }
                    cached.syncPair = pair
                    context.insert(cached)
                }
            }
            
            // Detect removals on target (Spotify) for delta sync
            if !isInitialSync {
                let liveSpotifyURIs = Set(spotifyTracks.compactMap { $0.track?.uri })
                let spotifyRemoved = cachedTracks.filter { isRemoved($0, from: .spotify, live: liveSpotifyURIs) }
                for cached in spotifyRemoved {
                    cached.source = .appleMusic
                    cached.removalFlag = .removedFromSpotify
                    cached.removalFlaggedAt = Date()
                }
            }
        }
        
        if persist { try? context.save() }
        
        // Fetch the updated cached tracks list from the context
        let pairId = pair.id
        var descriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate { $0.syncPair?.id == pairId }
        )
        descriptor.sortBy = [SortDescriptor(\.addedAt, order: .forward)]
        return (try? context.fetch(descriptor)) ?? cachedTracks
    }
}
