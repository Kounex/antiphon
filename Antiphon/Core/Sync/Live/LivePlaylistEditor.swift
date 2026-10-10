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
            let anchors = await appleMusicManager.libraryIDs(for: songs, in: playlist)
            let landed = songs.map { song in
                var track = CatalogTrack(song)
                if let libraryID = anchors[track.id] { track.id = libraryID }
                return track
            }
            if songs.count < tracks.count {
                throw PlaylistEditError.partial(landed: landed, underlying: OperationRunner.Failure.trackNotFound)
            }
            return landed
        }
    }

    func remove(_ tracks: [CatalogTrack], from playlistId: String, on platform: Platform) async throws {
        switch platform {
        case .spotify:
            try await spotifyClient.removeTracksFromPlaylist(playlistId: playlistId, trackUris: tracks.map(\.id))
        case .appleMusic:
            // Only reached when the seam's capabilities allow it: playlists
            // Antiphon created (D1). Others are guided.
            try await appleMusicManager.removeTracks(tracks, from: try await appleMusicPlaylist(playlistId))
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
    /// Library IDs (`i.`) can't be added from the catalog: those tracks get
    /// the release syncing would pick (original album first), or are left out.
    private func resolveSongs(_ tracks: [CatalogTrack]) async throws -> [Song] {
        let catalog = AppleMusicTrackCatalog(manager: appleMusicManager)
        let preferences = AppPreferences.shared.versionPreferences
        var catalogIds: [String?] = []
        for track in tracks {
            if !track.id.hasPrefix("i.") {
                catalogIds.append(track.id)
            } else {
                catalogIds.append(try await ReleaseResolver.catalogTrack(for: track, in: catalog, preferences: preferences)?.id)
            }
        }

        var byId: [String: Song] = [:]
        for batch in Array(Set(catalogIds.compactMap { $0 })).chunked(into: 25) {
            let request = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch.map { MusicItemID($0) })
            for song in try await request.response().items { byId[song.id.rawValue] = song }
        }
        return catalogIds.compactMap { $0.flatMap { byId[$0] } }
    }
}
