import Foundation
import MusicKit
import Observation
import UIKit

/// Manages Apple Music authorization and library access via MusicKit.
///
/// Fully `@MainActor`-isolated: observable auth state is UI-owned, and MusicKit
/// network calls suspend off the main actor internally. The `nonisolated init()`
/// allows Views to create instances as stored properties without requiring
/// `@MainActor` context during struct initialization.
@MainActor
@Observable
final class AppleMusicManager {
    
    // MARK: - Published State
    
    var authorizationStatus: MusicAuthorization.Status = .notDetermined
    var isAuthorized: Bool { authorizationStatus == .authorized }
    
    // MARK: - Init
    
    nonisolated init() {}
    
    // MARK: - Authorization
    
    /// Requests Apple Music authorization from the user.
    /// Presents a system prompt for library access.
    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
    }
    
    /// Refreshes the current authorization status without prompting.
    /// Call after init or in `.onAppear` to pick up the live status.
    func refreshStatus() {
        authorizationStatus = MusicAuthorization.currentStatus
    }
    
    // MARK: - Authorization Guard
    
    /// Validates Apple Music authorization, transparently re-requesting access
    /// when the status is `.notDetermined` (analogous to Spotify's token refresh).
    ///
    /// `MusicAuthorization.request()` is idempotent: if the user has already
    /// granted access it returns `.authorized` instantly without showing a
    /// dialog. This makes it safe to call from any context.
    private func ensureAuthorized() async throws {
        var live = MusicAuthorization.currentStatus
        
        if live == .notDetermined {
            live = await MusicAuthorization.request()
        }
        
        authorizationStatus = live
        guard live == .authorized else {
            throw AppleMusicError.notAuthorized
        }
    }
    
    // MARK: - Playlists
    
    /// Fetches all playlists from the user's Apple Music library.
    func fetchUserPlaylists() async throws -> [Playlist] {
        try await ensureAuthorized()
        
        var request = MusicLibraryRequest<Playlist>()
        request.sort(by: \.name, ascending: true)
        
        let response = try await request.response()
        
        // Collect all items across pages
        var playlists = Array(response.items)
        
        // Handle pagination if needed
        var currentBatch = response.items
        while currentBatch.hasNextBatch {
            if let nextBatch = try await currentBatch.nextBatch() {
                playlists.append(contentsOf: nextBatch)
                currentBatch = nextBatch
            } else {
                break
            }
        }
        
        return playlists
    }
    
    /// Fetches all tracks from a specific playlist, utilizing a local cache lookup closure
    /// and a batched catalog search to retrieve track ISRCs efficiently.
    func fetchPlaylistTracks(
        for playlist: Playlist,
        localISRCLookup: (@Sendable (_ ids: [String]) -> [String: String])? = nil
    ) async throws -> [AppleMusicTrackInfo] {
        try await ensureAuthorized()
        
        // Load tracks relationship
        let detailedPlaylist = try await playlist.with([.tracks])
        
        guard let tracks = detailedPlaylist.tracks else {
            return []
        }
        
        let trackIDs = tracks.map { $0.id.rawValue }
        
        // 1. Resolve ISRCs from local lookup if available
        var resolvedISRCs: [String: String] = [:]
        if let lookup = localISRCLookup {
            resolvedISRCs = lookup(trackIDs)
        }
        
        // 2. Identify missing IDs that require remote lookup. Playlist tracks
        // carry library IDs, which the catalog doesn't know — look up their
        // catalog ID instead, keyed back to the library ID.
        var catalogIDsByTrackID: [String: String] = [:]
        for track in tracks where resolvedISRCs[track.id.rawValue] == nil {
            if let catalogID = Self.catalogID(for: track) {
                catalogIDsByTrackID[track.id.rawValue] = catalogID
            }
        }
        let songIDsToFetch = Set(catalogIDsByTrackID.values).map { MusicItemID($0) }
        
        var catalogSongsByID: [String: Song] = [:]
        if !songIDsToFetch.isEmpty {
            let batches = songIDsToFetch.chunked(into: 100)
            for batch in batches {
                do {
                    let songRequest = MusicCatalogResourceRequest<Song>(matching: \.id, memberOf: batch)
                    let songResponse = try await songRequest.response()
                    for song in songResponse.items {
                        catalogSongsByID[song.id.rawValue] = song
                    }
                } catch {
                    print("[AppleMusic] Batch ISRC lookup failed for batch: \(error.localizedDescription)")
                }
            }
        }
        
        var trackInfos: [AppleMusicTrackInfo] = []
        
        // Process each track
        for track in tracks {
            var isrc = resolvedISRCs[track.id.rawValue]
            if isrc == nil,
               let catalogID = catalogIDsByTrackID[track.id.rawValue],
               let song = catalogSongsByID[catalogID] {
                isrc = song.isrc
            }
            
            let info = AppleMusicTrackInfo(
                id: track.id.rawValue,
                title: track.title,
                artist: track.artistName,
                albumName: track.albumTitle,
                isrc: isrc,
                durationMs: track.duration.map { Int($0 * 1000) },
                artworkURL: track.artwork?.url(width: 300, height: 300)?.absoluteString
            )
            trackInfos.append(info)
        }
        
        return trackInfos
    }
    
    // MARK: - Playlist Creation
    
    /// Creates a new playlist in the user's Apple Music library.
    func createPlaylist(name: String, description: String? = nil) async throws -> Playlist {
        try await ensureAuthorized()
        
        let playlist = try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: description
        )
        
        return playlist
    }
    
    // MARK: - Track Management
    
    /// Adds a song to a playlist.
    func addTrack(_ song: Song, to playlist: Playlist) async throws {
        try await ensureAuthorized()
        
        _ = try await MusicLibrary.shared.add(song, to: playlist)
    }
    
    /// Adds multiple songs to a playlist in order.
    ///
    /// Uses `MusicLibrary` one song at a time: playlists from
    /// `MusicLibraryRequest`/`createPlaylist` carry device-local IDs that the
    /// Apple Music REST endpoint (`/v1/me/library/playlists/{id}/tracks`)
    /// doesn't accept. On failure or cancellation, throws
    /// `AppleMusicError.partialAdd` carrying the IDs that did land, so callers
    /// can roll back only the unwritten songs.
    func addTracks(
        _ songs: [Song],
        to playlist: Playlist,
        onSongAdded: (@Sendable (_ addedCount: Int) async -> Void)? = nil
    ) async throws {
        try await ensureAuthorized()
        
        var addedSongIds = Set<String>()
        for song in songs {
            do {
                try Task.checkCancellation()
                _ = try await MusicLibrary.shared.add(song, to: playlist)
                addedSongIds.insert(song.id.rawValue)
                await onSongAdded?(addedSongIds.count)
            } catch {
                throw AppleMusicError.partialAdd(addedSongIds: addedSongIds, underlying: error)
            }
        }
        
        print("[AppleMusic] Added \(songs.count) tracks to playlist \(playlist.name)")
    }
    
    // MARK: - Artwork
    
    /// Fetches the playlist's artwork image and returns it as a Base64-encoded JPEG string.
    /// Sized and compressed to fit Spotify's ~256KB limit.
    func fetchPlaylistArtworkAsBase64JPEG(for playlist: Playlist, size: Int = 640) async throws -> String? {
        // Get the artwork URL from the playlist
        guard let artwork = playlist.artwork,
              let url = artwork.url(width: size, height: size) else {
            return nil
        }
        
        // Download the image data
        let (data, _) = try await URLSession.shared.data(from: url)

        // Decode and JPEG-compress off the main actor — this is CPU-bound work
        // that must not block the @MainActor-isolated class.
        return await Task.detached(priority: .userInitiated) {
            guard let uiImage = UIImage(data: data) else {
                return nil
            }

            // Compress as JPEG — start at 0.8 quality, reduce if over 256KB
            var quality: CGFloat = 0.8
            var jpegData = uiImage.jpegData(compressionQuality: quality)

            while let currentData = jpegData, currentData.count > 256_000, quality > 0.1 {
                quality -= 0.1
                jpegData = uiImage.jpegData(compressionQuality: quality)
            }

            guard let finalData = jpegData else {
                return nil
            }

            return finalData.base64EncodedString()
        }.value
    }
    
    // MARK: - Catalog Search
    
    /// Searches the Apple Music catalog for a song by ISRC code.
    /// This is the primary matching strategy for cross-platform sync.
    func searchByISRC(_ isrc: String) async throws -> Song? {
        try await ensureAuthorized()
        
        do {
            let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
            let response = try await request.response()
            return response.items.first
        } catch {
            print("[AppleMusic] ISRC search failed for '\(isrc)': \(error)")
            throw error
        }
    }
    
    /// Searches the Apple Music catalog by query string (fuzzy fallback).
    func searchCatalog(query: String, limit: Int = 10) async throws -> [Song] {
        try await ensureAuthorized()
        
        do {
            var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
            request.limit = limit
            
            let response = try await request.response()
            let songs = Array(response.songs)
            print("[AppleMusic] Catalog search for '\(query)': \(songs.count) results")
            return songs
        } catch {
            print("[AppleMusic] Catalog search failed for '\(query)': \(error)")
            throw error
        }
    }
}

// MARK: - Catalog ID Resolution

extension AppleMusicManager {
    /// The catalog ID behind a library track, when known.
    ///
    /// Library tracks expose it only inside their play parameters
    /// (`catalogId`), which MusicKit doesn't surface as a property. Falls back
    /// to the track's own ID unless that is a known library ID (`i.` prefix).
    nonisolated static func catalogID(for track: Track) -> String? {
        if let playParameters = track.playParameters,
           let data = try? JSONEncoder().encode(playParameters),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let catalogId = json["catalogId"] as? String, !catalogId.isEmpty {
            return catalogId
        }
        let id = track.id.rawValue
        return id.hasPrefix("i.") ? nil : id
    }
}

// MARK: - Bridge Types

/// A lightweight representation of an Apple Music track for use with SwiftData.
/// MusicKit types (Song, Track) are not SwiftData-compatible, so we extract
/// the relevant fields into this plain struct.
struct AppleMusicTrackInfo: Identifiable, Sendable {
    let id: String             // MusicItemID.rawValue
    let title: String
    let artist: String
    let albumName: String?
    let isrc: String?
    let durationMs: Int?
    let artworkURL: String?
}

// MARK: - Errors

enum AppleMusicError: LocalizedError {
    case notAuthorized
    case invalidURL
    case playlistNotFound
    case trackNotFound(isrc: String)
    case addTrackFailed(String)
    /// A multi-song add stopped partway; `addedSongIds` reached the playlist.
    case partialAdd(addedSongIds: Set<String>, underlying: Error)
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Apple Music access not authorized. Please grant access in Settings."
        case .invalidURL:
            return "Invalid Apple Music API URL."
        case .playlistNotFound:
            return "The Apple Music playlist could not be found."
        case .trackNotFound(let isrc):
            return "No matching track found on Apple Music for ISRC: \(isrc)"
        case .addTrackFailed(let detail):
            return "Failed to add track to playlist: \(detail)"
        case .partialAdd(_, let underlying):
            return underlying.localizedDescription
        }
    }
}
