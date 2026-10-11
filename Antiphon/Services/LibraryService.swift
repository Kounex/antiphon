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
    /// Made by the person (not followed, not editorial).
    var isOwn: Bool = true
    var isCollaborative: Bool = false
}

/// Who put a track in a collaborative playlist. Collaborators aren't named:
/// that would cost a request each.
enum AddedBy: Hashable, Sendable {
    case you
    case collaborator
}

/// A track as it sits in a library playlist.
struct LibraryEntry: Hashable, Sendable {
    let track: CatalogTrack
    let addedBy: AddedBy?
    /// Spotify user ID, for looking up names when the person asks.
    var addedByUserId: String? = nil
}

/// Both libraries, read-only.
protocol LibraryService: Sendable {
    func playlists(on platform: Platform) async throws -> [LibraryPlaylist]
    func tracks(of playlist: LibraryPlaylist) async throws -> [CatalogTrack]
    /// Tracks with who added them, where the platform says.
    func entries(of playlist: LibraryPlaylist) async throws -> [LibraryEntry]
    /// Spotify display names, one request per user. Users whose name
    /// couldn't be read are left out.
    func displayNames(for userIds: Set<String>) async -> [String: String]
}

extension LibraryService {
    func entries(of playlist: LibraryPlaylist) async throws -> [LibraryEntry] {
        try await tracks(of: playlist).map { LibraryEntry(track: $0, addedBy: nil) }
    }

    func displayNames(for userIds: Set<String>) async -> [String: String] { [:] }
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
                    isEditable: playlist.isEditable(byUserId: me.id), blockedReason: blocked,
                    isOwn: isMine, isCollaborative: playlist.collaborative
                )
            }
        case .appleMusic:
            return try await appleMusicManager.fetchUserPlaylists().map { playlist in
                let isOwn = AppleMusicOwnership.isOwn(kind: playlist.kind)
                return LibraryPlaylist(
                    platform: .appleMusic, id: playlist.id.rawValue, name: playlist.name, trackCount: nil,
                    artworkURL: playlist.artwork?.url(width: 300, height: 300),
                    detail: isOwn ? "Apple Music" : "by \(playlist.curatorName ?? "Apple Music")",
                    isEditable: isOwn, blockedReason: nil, isOwn: isOwn
                )
            }
        }
    }

    func entries(of playlist: LibraryPlaylist) async throws -> [LibraryEntry] {
        guard playlist.platform == .spotify else {
            return try await tracks(of: playlist).map { LibraryEntry(track: $0, addedBy: nil) }
        }
        let me = playlist.isCollaborative ? try await spotifyClient.getCurrentUser().id : nil
        return try await spotifyClient.getPlaylistTracks(playlistId: playlist.id).compactMap { item in
            guard let track = item.track else { return nil }
            let addedBy: AddedBy? = me.flatMap { me in item.addedBy.map { $0.id == me ? .you : .collaborator } }
            return LibraryEntry(track: CatalogTrack(track), addedBy: addedBy, addedByUserId: item.addedBy?.id)
        }
    }

    func displayNames(for userIds: Set<String>) async -> [String: String] {
        var names: [String: String] = [:]
        for id in userIds {
            do {
                if let name = try await spotifyClient.getUser(id: id).displayName, !name.isEmpty { names[id] = name }
            } catch {
                print("[LibraryService] No name for a collaborator: \(error.localizedDescription)")
            }
        }
        return names
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

/// Which library playlists are the person's own. Seen on device: playlists
/// they or Antiphon made report `userShared` or no kind; editorial ones,
/// Apple's personal mixes and Replay report those kinds.
enum AppleMusicOwnership {
    static func isOwn(kind: Playlist.Kind?) -> Bool {
        guard let kind else { return true }
        return ![.editorial, .external, .personalMix, .replay].contains(kind)
    }
}
