import Foundation
import SwiftData

/// Aligns the local database cache with the source playlist, updating existing tracks and inserting new ones.
struct CacheAligner {

    /// Which side Stage A aligns from. Two-way seams use Spotify unless it's
    /// empty and Apple Music isn't.
    static func isSpotifySource(direction: SyncDirection, spotifyCount: Int, appleMusicCount: Int) -> Bool {
        if direction == .bidirectional {
            return !(spotifyCount == 0 && appleMusicCount > 0)
        }
        return direction != .appleToSpotify
    }
    
    /// Updates the local cache with the latest state of the source playlist, utilizing O(1) dictionary lookups.
    /// Returns the updated list of cached tracks.
    static func alignCache(
        in context: ModelContext,
        pair: SyncPair,
        cachedTracks: [CachedTrack],
        spotifyTracks: [SpotifyPlaylistItem],
        appleMusicTracks: [AppleMusicTrackInfo],
        isInitialSync: Bool,
        isSpotifySource: Bool,
        persist: Bool = true
    ) -> [CachedTrack] {
        let baseDate = Date()
        
        if isInitialSync {
            // Clear old cache
            for track in cachedTracks {
                context.delete(track)
            }
            if persist { try? context.save() }
            
            var insertedTracks: [CachedTrack] = []
            if isSpotifySource {
                for (index, item) in spotifyTracks.enumerated() {
                    guard let sTrack = item.track else { continue }
                    let isrc = sTrack.isrc ?? "local-\(sTrack.uri)"
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
                        syncState: .pending
                    )
                    cached.syncPair = pair
                    cached.addedAt = baseDate.addingTimeInterval(TimeInterval(index))
                    context.insert(cached)
                    insertedTracks.append(cached)
                }
            } else {
                for (index, appleTrack) in appleMusicTracks.enumerated() {
                    let isrc = appleTrack.isrc ?? "local-\(appleTrack.id)"
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
                        syncState: .pending
                    )
                    cached.syncPair = pair
                    cached.addedAt = baseDate.addingTimeInterval(TimeInterval(index))
                    context.insert(cached)
                    insertedTracks.append(cached)
                }
            }
            if persist { try? context.save() }
            return insertedTracks
            
        } else {
            // Delta sync: update source tracks in cache
            var updatedTracks = cachedTracks
            
            if isSpotifySource {
                let liveSpotifyURIs = Set(spotifyTracks.compactMap { $0.track?.uri })
                
                // Detect removals from Spotify (source)
                let spotifyRemoved = cachedTracks.filter { cached in
                    cached.removalKeptAt == nil &&
                    (cached.source == .spotify || cached.source == .both) &&
                    (cached.spotifyTrackUri != nil && !liveSpotifyURIs.contains(cached.spotifyTrackUri!))
                }
                
                for cached in spotifyRemoved {
                    cached.removalFlag = .removedFromSource
                    cached.removalFlaggedAt = Date()
                }
                
                // Map existing tracks by URI and ISRC for O(1) matching
                var cacheBySpotifyUri: [String: CachedTrack] = [:]
                var cacheByISRC: [String: CachedTrack] = [:]
                
                for track in cachedTracks {
                    if let uri = track.spotifyTrackUri {
                        cacheBySpotifyUri[uri] = track
                    }
                    let lowercasedIsrc = track.isrc.lowercased()
                    if !lowercasedIsrc.hasPrefix("local-") {
                        cacheByISRC[lowercasedIsrc] = track
                    }
                }
                
                // Add new source tracks
                for (index, item) in spotifyTracks.enumerated() {
                    guard let sTrack = item.track else { continue }
                    
                    var existing: CachedTrack? = cacheBySpotifyUri[sTrack.uri]
                    if existing == nil, let sIsrc = sTrack.isrc, !sIsrc.isEmpty {
                        existing = cacheByISRC[sIsrc.lowercased()]
                    }
                    
                    if let existingTrack = existing {
                        // Update existing cached track
                        existingTrack.spotifyTrackUri = sTrack.uri
                        existingTrack.adoptArtwork(url: sTrack.album?.images?.first?.url)
                        if existingTrack.source == .appleMusic {
                            existingTrack.source = .both
                        }
                        existingTrack.removalFlag = nil
                        existingTrack.removalFlaggedAt = nil
                        existingTrack.removalKeptAt = nil
                        existingTrack.addedAt = baseDate.addingTimeInterval(TimeInterval(index))
                    } else {
                        let isrc = sTrack.isrc ?? "local-\(sTrack.uri)"
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
                            syncState: .pending
                        )
                        cached.syncPair = pair
                        cached.addedAt = baseDate.addingTimeInterval(TimeInterval(index))
                        context.insert(cached)
                        updatedTracks.append(cached)
                    }
                }
            } else {
                let liveAppleIDs = Set(appleMusicTracks.map { $0.id })
                
                // Detect removals from Apple Music (source)
                let appleRemoved = cachedTracks.filter { cached in
                    cached.removalKeptAt == nil &&
                    (cached.source == .appleMusic || cached.source == .both) &&
                    (cached.appleMusicTrackId != nil && !liveAppleIDs.contains(cached.appleMusicTrackId!))
                }
                
                for cached in appleRemoved {
                    cached.removalFlag = .removedFromSource
                    cached.removalFlaggedAt = Date()
                }
                
                // Map existing tracks by ID and ISRC for O(1) matching
                var cacheByAppleId: [String: CachedTrack] = [:]
                var cacheByISRC: [String: CachedTrack] = [:]
                
                for track in cachedTracks {
                    if let amId = track.appleMusicTrackId {
                        cacheByAppleId[amId] = track
                    }
                    let lowercasedIsrc = track.isrc.lowercased()
                    if !lowercasedIsrc.hasPrefix("local-") {
                        cacheByISRC[lowercasedIsrc] = track
                    }
                }
                
                // Add new source tracks
                for (index, appleTrack) in appleMusicTracks.enumerated() {
                    var existing: CachedTrack? = cacheByAppleId[appleTrack.id]
                    if existing == nil, let amIsrc = appleTrack.isrc, !amIsrc.isEmpty {
                        existing = cacheByISRC[amIsrc.lowercased()]
                    }
                    
                    if let existingTrack = existing {
                        // Update existing cached track
                        existingTrack.appleMusicTrackId = appleTrack.id
                        existingTrack.adoptArtwork(url: appleTrack.artworkURL)
                        if existingTrack.source == .spotify {
                            existingTrack.source = .both
                        }
                        existingTrack.removalFlag = nil
                        existingTrack.removalFlaggedAt = nil
                        existingTrack.removalKeptAt = nil
                        existingTrack.addedAt = baseDate.addingTimeInterval(TimeInterval(index))
                    } else {
                        let isrc = appleTrack.isrc ?? "local-\(appleTrack.id)"
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
                            syncState: .pending
                        )
                        cached.syncPair = pair
                        cached.addedAt = baseDate.addingTimeInterval(TimeInterval(index))
                        context.insert(cached)
                        updatedTracks.append(cached)
                    }
                }
            }
            if persist { try? context.save() }
            return updatedTracks
        }
    }
}
