import Foundation

/// Links that open a seam's playlists in their own apps.
enum SeamLinks {
    /// `nil` while the playlist is still waiting to be created.
    static func playlistURL(_ side: SeamSide) -> URL? {
        guard !side.playlistId.isEmpty, !side.playlistId.hasPrefix("pending-creation-") else { return nil }
        switch side.platform {
        case .spotify:
            return URL(string: "https://open.spotify.com/playlist/\(side.playlistId)")
        case .appleMusic:
            // A library playlist (`p.…`), the link the Music app itself shares.
            return URL(string: "https://music.apple.com/library/playlist/\(side.playlistId)")
        }
    }
}
