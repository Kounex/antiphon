import Foundation
import MusicKit

/// A playlist in one of the person's libraries.
struct LibraryPlaylist: Identifiable, Hashable, Sendable {
    let platform: Platform
    let id: String
    let name: String
    let trackCount: Int?
    let artworkURL: URL?
    /// "64 tracks · yours", "collaborative", "by Spotify".
    let detail: String
    let isEditable: Bool
    /// Set when the platform won't let Antiphon read or change it.
    let blockedReason: String?
}

/// Both libraries, read-only.
protocol LibraryService: Sendable {
    func playlists(on platform: Platform) async throws -> [LibraryPlaylist]
    func tracks(of playlist: LibraryPlaylist) async throws -> [CatalogTrack]
}

/// `LibraryService` over the existing clients.
struct LiveLibraryService: LibraryService {
    let spotifyClient: SpotifyAPIClient
    let appleMusicManager: AppleMusicManager

    func playlists(on platform: Platform) async throws -> [LibraryPlaylist] {
        switch platform {
        case .spotify:
            let me = try await spotifyClient.getCurrentUser()
            return try await spotifyClient.getAllPlaylists().map { playlist in
                let isMine = playlist.owner.id == me.id
                // Spotify blocks apps created after Nov 2024 from its own
                // editorial and algorithmic playlists.
                let blocked = playlist.owner.id == "spotify"
                    ? "Made by Spotify. Spotify doesn't let apps read these." : nil
                var parts = ["\(playlist.tracks.total) tracks"]
                if playlist.collaborative { parts.append("collaborative") }
                else if isMine { parts.append("yours") }
                else { parts.append("by \(playlist.owner.displayName ?? playlist.owner.id)") }
                return LibraryPlaylist(
                    platform: .spotify, id: playlist.id, name: playlist.name, trackCount: playlist.tracks.total,
                    artworkURL: playlist.images?.first.flatMap { URL(string: $0.url) },
                    detail: parts.joined(separator: " · "),
                    isEditable: playlist.isEditable(byUserId: me.id), blockedReason: blocked
                )
            }
        case .appleMusic:
            return try await appleMusicManager.fetchUserPlaylists().map { playlist in
                LibraryPlaylist(
                    platform: .appleMusic, id: playlist.id.rawValue, name: playlist.name, trackCount: nil,
                    artworkURL: playlist.artwork?.url(width: 300, height: 300),
                    detail: "Apple Music", isEditable: true, blockedReason: nil
                )
            }
        }
    }

    func tracks(of playlist: LibraryPlaylist) async throws -> [CatalogTrack] {
        switch playlist.platform {
        case .spotify:
            return try await spotifyClient.getPlaylistTracks(playlistId: playlist.id).compactMap { $0.track.map(CatalogTrack.init) }
        case .appleMusic:
            guard let match = try await appleMusicManager.fetchUserPlaylists().first(where: { $0.id.rawValue == playlist.id }) else {
                throw SyncError.appleMusicPlaylistNotFound
            }
            return try await appleMusicManager.fetchPlaylistTracks(for: match).map(CatalogTrack.init)
        }
    }
}
