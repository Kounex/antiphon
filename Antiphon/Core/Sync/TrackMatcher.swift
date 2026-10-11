import Foundation
import MusicKit

/// Compares tracks across Spotify and Apple Music by title, artist and
/// length: Stage A's matching of playlist rows and the "already in the
/// playlist" check. Catalog lookups belong to `MatchFinder`, which plans.
struct TrackMatcher: Sendable {

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
        } else if !candidateTitle.isEmpty, !targetTitle.isEmpty,
                  candidateTitle.contains(targetTitle) || targetTitle.contains(candidateTitle) {
            // contains("") is always true — without the emptiness guards an
            // all-symbol title would earn partial credit on everything.
            score += 0.30
        }

        // Artist match (weight: 0.40)
        maxScore += 0.40
        if candidateArtist == targetArtist {
            score += 0.40
        } else if !candidateArtist.isEmpty, !targetArtist.isEmpty,
                  candidateArtist.contains(targetArtist) || targetArtist.contains(candidateArtist) {
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
