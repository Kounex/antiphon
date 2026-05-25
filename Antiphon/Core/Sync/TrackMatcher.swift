import Foundation
import MusicKit

/// Handles cross-platform track matching using ISRC codes as the primary
/// strategy, with a fuzzy search fallback for tracks without ISRC data.
///
/// ISRC (International Standard Recording Code) is a global identifier
/// for sound recordings, making it the most reliable way to match
/// the same song across Spotify and Apple Music.
struct TrackMatcher: Sendable {
    
    let spotifyClient: SpotifyAPIClient
    let appleMusicManager: AppleMusicManager
    
    // MARK: - Apple Music Lookup
    
    /// Finds an Apple Music song matching the given ISRC code.
    /// Falls back to fuzzy search if ISRC lookup returns no results and
    /// title/artist metadata is provided.
    func findAppleMusicTrack(
        forISRC isrc: String,
        title: String? = nil,
        artist: String? = nil,
        durationMs: Int? = nil
    ) async throws -> Song? {
        // Primary: ISRC lookup
        if let song = try await appleMusicManager.searchByISRC(isrc) {
            return song
        }
        
        // Fallback: fuzzy search by title + artist
        if let title, let artist {
            return try await findAppleMusicTrack(
                title: title,
                artist: artist,
                durationMs: durationMs
            )
        }
        
        return nil
    }
    
    /// Finds an Apple Music song using fuzzy search (artist + title).
    /// Used when ISRC matching fails.
    func findAppleMusicTrack(title: String, artist: String, durationMs: Int?) async throws -> Song? {
        let normalizedTitle = title.normalizedForMatching
        let normalizedArtist = artist.normalizedForMatching
        let query = "\(normalizedArtist) \(normalizedTitle)"
        
        let results = try await appleMusicManager.searchCatalog(query: query, limit: 5)
        
        return bestMatch(
            from: results,
            title: normalizedTitle,
            artist: normalizedArtist,
            durationMs: durationMs
        )
    }
    
    // MARK: - Spotify Lookup
    
    /// Finds a Spotify track matching the given ISRC code.
    /// Falls back to fuzzy search if ISRC lookup returns no results.
    func findSpotifyTrack(
        forISRC isrc: String,
        title: String? = nil,
        artist: String? = nil,
        durationMs: Int? = nil
    ) async throws -> SpotifyTrack? {
        if let track = try await spotifyClient.searchByISRC(isrc) {
            return track
        }
        
        // Fallback: fuzzy search by title + artist
        if let title, let artist {
            return try await findSpotifyTrack(
                title: title,
                artist: artist,
                durationMs: durationMs
            )
        }
        
        return nil
    }
    
    /// Finds a Spotify track using fuzzy search (artist + title).
    func findSpotifyTrack(title: String, artist: String, durationMs: Int?) async throws -> SpotifyTrack? {
        let normalizedTitle = title.normalizedForMatching
        let normalizedArtist = artist.normalizedForMatching
        let query = "\(normalizedArtist) \(normalizedTitle)"
        
        let results = try await spotifyClient.search(query: query, limit: 5)
        
        return bestSpotifyMatch(
            from: results,
            title: normalizedTitle,
            artist: normalizedArtist,
            durationMs: durationMs
        )
    }
    
    // MARK: - Fuzzy Matching
    
    /// Selects the best Apple Music match from search results based on
    /// title similarity, artist match, and duration proximity.
    private func bestMatch(
        from songs: [Song],
        title: String,
        artist: String,
        durationMs: Int?
    ) -> Song? {
        var bestScore: Double = 0
        var bestSong: Song?
        
        for song in songs {
            let score = matchScore(
                candidateTitle: song.title.normalizedForMatching,
                candidateArtist: song.artistName.normalizedForMatching,
                candidateDurationMs: song.duration.map { Int($0 * 1000) },
                targetTitle: title,
                targetArtist: artist,
                targetDurationMs: durationMs
            )
            
            if score > bestScore {
                bestScore = score
                bestSong = song
            }
        }
        
        // Only return matches above 60% confidence
        return bestScore >= 0.6 ? bestSong : nil
    }
    
    /// Selects the best Spotify match from search results.
    private func bestSpotifyMatch(
        from tracks: [SpotifyTrack],
        title: String,
        artist: String,
        durationMs: Int?
    ) -> SpotifyTrack? {
        var bestScore: Double = 0
        var bestTrack: SpotifyTrack?
        
        for track in tracks {
            let score = matchScore(
                candidateTitle: track.name.normalizedForMatching,
                candidateArtist: track.primaryArtist.normalizedForMatching,
                candidateDurationMs: track.durationMs,
                targetTitle: title,
                targetArtist: artist,
                targetDurationMs: durationMs
            )
            
            if score > bestScore {
                bestScore = score
                bestTrack = track
            }
        }
        
        return bestScore >= 0.6 ? bestTrack : nil
    }
    
    /// Calculates a match confidence score (0.0 – 1.0) between a candidate
    /// and target track based on title, artist, and duration.
    func matchScore(
        candidateTitle: String,
        candidateArtist: String,
        candidateDurationMs: Int?,
        targetTitle: String,
        targetArtist: String,
        targetDurationMs: Int?
    ) -> Double {
        var score: Double = 0
        var maxScore: Double = 0
        
        // Title match (weight: 0.45)
        maxScore += 0.45
        if candidateTitle == targetTitle {
            score += 0.45
        } else if candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle) {
            score += 0.30
        }
        
        // Artist match (weight: 0.40)
        maxScore += 0.40
        if candidateArtist == targetArtist {
            score += 0.40
        } else if candidateArtist.contains(targetArtist) || targetArtist.contains(candidateArtist) {
            score += 0.25
        }
        
        // Duration match (weight: 0.15) — within 5 seconds tolerance
        if let candidateMs = candidateDurationMs, let targetMs = targetDurationMs {
            maxScore += 0.15
            let diff = abs(candidateMs - targetMs)
            if diff <= 5000 {  // 5 seconds
                score += 0.15 * (1.0 - Double(diff) / 5000.0)
            }
        }
        
        return maxScore > 0 ? score / maxScore : 0
    }
    
    // MARK: - Local List Matching Helpers
    
    /// Determines if a live Spotify track and a live Apple Music track are the same song.
    func isMatch(
        spotifyItem: SpotifyPlaylistItem,
        appleTrack: AppleMusicTrackInfo
    ) -> Bool {
        guard let sTrack = spotifyItem.track else { return false }
        
        // 1. Check ISRC if both present
        if let sIsrc = sTrack.isrc, !sIsrc.isEmpty,
           let aIsrc = appleTrack.isrc, !aIsrc.isEmpty {
            if sIsrc.lowercased() == aIsrc.lowercased() {
                return true
            }
        }
        
        // 2. Fuzzy match title + artist
        let score = matchScore(
            candidateTitle: appleTrack.title.normalizedForMatching,
            candidateArtist: appleTrack.artist.normalizedForMatching,
            candidateDurationMs: appleTrack.durationMs,
            targetTitle: sTrack.name.normalizedForMatching,
            targetArtist: sTrack.primaryArtist.normalizedForMatching,
            targetDurationMs: sTrack.durationMs
        )
        return score >= 0.75
    }
    
    /// Determines if an Apple Music catalog Song matches a track info from the playlist.
    func isMatch(
        song: Song,
        appleTrack: AppleMusicTrackInfo
    ) -> Bool {
        // 1. Check ID
        if song.id.rawValue == appleTrack.id {
            return true
        }
        
        // 2. Check ISRC if both present
        if let sIsrc = song.isrc, !sIsrc.isEmpty,
           let aIsrc = appleTrack.isrc, !aIsrc.isEmpty {
            if sIsrc.lowercased() == aIsrc.lowercased() {
                return true
            }
        }
        
        // 3. Fuzzy match title + artist
        let score = matchScore(
            candidateTitle: appleTrack.title.normalizedForMatching,
            candidateArtist: appleTrack.artist.normalizedForMatching,
            candidateDurationMs: appleTrack.durationMs,
            targetTitle: song.title.normalizedForMatching,
            targetArtist: song.artistName.normalizedForMatching,
            targetDurationMs: song.duration.map { Int($0 * 1000) }
        )
        return score >= 0.75
    }
    
    /// Determines if a Spotify catalog track matches a playlist item.
    func isMatch(
        spotifyTrack: SpotifyTrack,
        spotifyItem: SpotifyPlaylistItem
    ) -> Bool {
        guard let sTrack = spotifyItem.track else { return false }
        
        // 1. Check URI or ID
        if spotifyTrack.uri == sTrack.uri || (spotifyTrack.id != nil && spotifyTrack.id == sTrack.id) {
            return true
        }
        
        // 2. Check ISRC if both present
        if let sIsrc = spotifyTrack.isrc, !sIsrc.isEmpty,
           let aIsrc = sTrack.isrc, !aIsrc.isEmpty {
            if sIsrc.lowercased() == aIsrc.lowercased() {
                return true
            }
        }
        
        // 3. Fuzzy match title + artist
        let score = matchScore(
            candidateTitle: sTrack.name.normalizedForMatching,
            candidateArtist: sTrack.primaryArtist.normalizedForMatching,
            candidateDurationMs: sTrack.durationMs,
            targetTitle: spotifyTrack.name.normalizedForMatching,
            targetArtist: spotifyTrack.primaryArtist.normalizedForMatching,
            targetDurationMs: spotifyTrack.durationMs
        )
        return score >= 0.75
    }
}
