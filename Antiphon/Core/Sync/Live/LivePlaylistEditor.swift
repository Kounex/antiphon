import Foundation
import MusicKit

/// `PlaylistEditor` over the existing `SpotifyAPIClient` and `AppleMusicManager`.
struct LivePlaylistEditor: PlaylistEditor {
    let spotifyClient: SpotifyAPIClient
    let appleMusicManager: AppleMusicManager

    func add(_ tracks: [CatalogTrack], to playlistId: String, on platform: Platform) async throws -> [CatalogTrack] {
        switch platform {
        case .spotify:
            try await spotifyClient.addTracksToPlaylist(playlistId: playlistId, trackUris: tracks.map(\.id))
            return tracks

        case .appleMusic:
            let playlist = try await appleMusicPlaylist(playlistId)
            let songs = try await resolveSongs(tracks)
            do {
                try await appleMusicManager.addTracks(songs, to: playlist)
            } catch AppleMusicError.partialAdd(let addedIds, let underlying) {
                throw PlaylistEditError.partial(
                    landed: songs.filter { addedIds.contains($0.id.rawValue) }.map(CatalogTrack.init),
                    underlying: underlying
                )
            }
            if songs.count < tracks.count {
                throw PlaylistEditError.partial(landed: songs.map(CatalogTrack.init), underlying: OperationRunner.Failure.trackNotFound)
            }
            return songs.map(CatalogTrack.init)
        }
    }

    func remove(_ tracks: [CatalogTrack], from playlistId: String, on platform: Platform) async throws {
        switch platform {
        case .spotify:
            try await spotifyClient.removeTracksFromPlaylist(playlistId: playlistId, trackUris: tracks.map(\.id))
        case .appleMusic:
            // Not verified on a device yet (D1); callers treat these as guided.
            throw PlaylistEditError.unsupported
        }
    }

    func tracks(in playlistId: String, on platform: Platform) async throws -> [CatalogTrack] {
        switch platform {
        case .spotify:
            return try await spotifyClient.getPlaylistTracks(playlistId: playlistId).compactMap { $0.track.map(CatalogTrack.init) }
        case .appleMusic:
            let playlist = try await appleMusicPlaylist(playlistId)
            return try await appleMusicManager.fetchPlaylistTracks(for: playlist).map(CatalogTrack.init)
        }
    }

    // MARK: - Private

    private func appleMusicPlaylist(_ id: String) async throws -> Playlist {
        let playlists = try await appleMusicManager.fetchUserPlaylists()
        guard let playlist = playlists.first(where: { $0.id.rawValue == id }) else {
            throw SyncError.appleMusicPlaylistNotFound
        }
        return playlist
    }

    /// Catalog songs for the tracks: by catalog ID when known, otherwise by
    /// ISRC (library IDs like "i.…" aren't catalog IDs).
    private func resolveSongs(_ tracks: [CatalogTrack]) async throws -> [Song] {
        let catalogIds = tracks.map(\.id).filter { !$0.hasPrefix("i.") }
        var byId: [String: Song] = [:]
        for batch in catalogIds.chunked(into: 25) {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            for song in try await request.response().items { byId[song.id.rawValue] = song }
        }

        var songs: [Song] = []
        for track in tracks {
            if let song = byId[track.id] {
                songs.append(song)
            } else if let isrc = track.isrc, let song = try await appleMusicManager.searchByISRC(isrc) {
                songs.append(song)
            }
        }
        return songs
    }
}
