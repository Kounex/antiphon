import Foundation
import SwiftData

/// Handles cache cleaning, deduplication, and dead track pruning for a sync pair.
struct PlaylistCachePruner {
    
    /// Deduplicates cached tracks sharing the same ISRC or platform IDs in O(N) complexity.
    /// Returns the array of tracks that should be kept.
    static func deduplicate(
        in context: ModelContext,
        cachedTracksFetch: [CachedTrack]
    ) -> [CachedTrack] {
        var deduped = false
        var tracksToKeep: [CachedTrack] = []
        var tracksToDelete: [CachedTrack] = []
        
        // Maps to track unique properties for O(1) matching
        var seenByISRC: [String: CachedTrack] = [:]
        var seenBySpotifyUri: [String: CachedTrack] = [:]
        var seenByAppleId: [String: CachedTrack] = [:]
        
        for track in cachedTracksFetch {
            var duplicate: CachedTrack?
            
            // 1. Check ISRC duplicate (if not local)
            let lowercasedIsrc = track.isrc.lowercased()
            if !lowercasedIsrc.hasPrefix("local-") {
                duplicate = seenByISRC[lowercasedIsrc]
            }
            
            // 2. Check Spotify URI duplicate
            if duplicate == nil, let uri = track.spotifyTrackUri {
                duplicate = seenBySpotifyUri[uri]
            }
            
            // 3. Check Apple Music ID duplicate
            if duplicate == nil, let amId = track.appleMusicTrackId {
                duplicate = seenByAppleId[amId]
            }
            
            if let duplicate {
                // Merge track info into duplicate
                if duplicate.spotifyTrackUri == nil {
                    duplicate.spotifyTrackUri = track.spotifyTrackUri
                }
                if duplicate.appleMusicTrackId == nil {
                    duplicate.appleMusicTrackId = track.appleMusicTrackId
                }
                
                // Merge source
                if duplicate.source == .spotify && track.source == .appleMusic {
                    duplicate.source = .both
                } else if duplicate.source == .appleMusic && track.source == .spotify {
                    duplicate.source = .both
                } else if track.source == .both {
                    duplicate.source = .both
                }
                
                // Merge syncState
                if duplicate.syncState != .synced && track.syncState == .synced {
                    duplicate.syncState = .synced
                }
                
                // Merge removalFlag (keep nil if either is nil)
                if track.removalFlag == nil || duplicate.removalFlag == nil {
                    duplicate.removalFlag = nil
                    duplicate.removalFlaggedAt = nil
                }
                
                tracksToDelete.append(track)
                deduped = true
            } else {
                // Register in Seen Maps
                if !lowercasedIsrc.hasPrefix("local-") {
                    seenByISRC[lowercasedIsrc] = track
                }
                if let uri = track.spotifyTrackUri {
                    seenBySpotifyUri[uri] = track
                }
                if let amId = track.appleMusicTrackId {
                    seenByAppleId[amId] = track
                }
                tracksToKeep.append(track)
            }
        }
        
        if deduped {
            print("[PlaylistCachePruner] Deduplicated \(tracksToDelete.count) tracks in cache.")
            for track in tracksToDelete {
                context.delete(track)
            }
            try? context.save()
        }
        
        return tracksToKeep
    }
    
    /// Prunes cached tracks that are no longer present in either live playlist (e.g. user manually deleted a song on both sides).
    /// Returns the array of tracks that are still active.
    static func pruneGoneTracks(
        in context: ModelContext,
        cachedTracks: [CachedTrack],
        liveSpotifyURIs: Set<String>,
        liveAppleIDs: Set<String>
    ) -> [CachedTrack] {
        let goneTracks = cachedTracks.filter { cached in
            let inSpotify = cached.spotifyTrackUri != nil && liveSpotifyURIs.contains(cached.spotifyTrackUri!)
            let inAppleMusic = cached.appleMusicTrackId != nil && liveAppleIDs.contains(cached.appleMusicTrackId!)
            return !inSpotify && !inAppleMusic
        }
        
        guard !goneTracks.isEmpty else { return cachedTracks }
        
        print("[PlaylistCachePruner] Pruning \(goneTracks.count) tracks no longer in either live playlist.")
        for cached in goneTracks {
            context.delete(cached)
        }
        try? context.save()
        
        return cachedTracks.filter { cached in !goneTracks.contains(where: { $0.id == cached.id }) }
    }
}
