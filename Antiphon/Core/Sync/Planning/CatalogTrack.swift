import Foundation

/// A platform-neutral description of one track, used by matching and planning.
///
/// MusicKit's `Song` can't be constructed outside MusicKit, so everything that
/// decides *what* to sync works on this value type. `Song` and `SpotifyTrack`
/// are converted at the edges.
struct CatalogTrack: Hashable, Sendable, Codable {
    var platform: Platform
    /// Spotify URI, or Apple Music catalog/library ID.
    var id: String
    var title: String
    var artist: String
    var album: String? = nil
    var durationMs: Int? = nil
    var isrc: String? = nil
    var isExplicit: Bool? = nil
    var releaseYear: Int? = nil
    var artworkURL: String? = nil
    /// A short audio preview (Apple Music catalog songs only).
    var previewURL: String? = nil

    /// A web link to the track on its platform, when one can be built.
    var webURL: URL? {
        switch platform {
        case .spotify:
            guard let id = id.split(separator: ":").last, id != Substring(self.id) else { return nil }
            return URL(string: "https://open.spotify.com/track/\(id)")
        case .appleMusic:
            return nil
        }
    }
}

/// Why Antiphon thinks two tracks are the same recording, strongest first.
enum MatchReason: String, Codable, Sendable {
    case isrc
    case titleArtistDuration
    case versionDifference
    case titleOnly
    /// Chosen by the person, not scored.
    case manual
}

struct MatchScore: Equatable, Sendable {
    /// 0–100.
    let confidence: Int
    let reason: MatchReason
}
