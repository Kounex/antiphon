import Foundation

/// A music streaming platform supported by Antiphon.
enum Platform: String, CaseIterable, Codable, Sendable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"

    /// The platform on the other side of a seam.
    var other: Platform {
        switch self {
        case .spotify: .appleMusic
        case .appleMusic: .spotify
        }
    }
}
