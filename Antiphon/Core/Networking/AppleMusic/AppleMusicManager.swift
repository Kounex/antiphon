import Foundation
import MusicKit
import Observation
import UIKit

/// Manages Apple Music authorization and library access via MusicKit.
///
/// MusicKit handles all token management automatically — no manual JWT
/// generation or refresh logic needed. The framework signs API calls
/// behind the scenes once the user grants authorization.
@Observable
final class AppleMusicManager: @unchecked Sendable {
    
    // MARK: - Published State
    
    var authorizationStatus: MusicAuthorization.Status = MusicAuthorization.currentStatus
    var isAuthorized: Bool { authorizationStatus == .authorized }
    
    // MARK: - Authorization
    
    /// Requests Apple Music authorization from the user.
    /// Presents a system prompt for library access.
    @MainActor
    func requestAuthorization() async {
        let status = await MusicAuthorization.request()
        authorizationStatus = status
    }
    
    /// Refreshes the current authorization status without prompting.
    @MainActor
    func refreshStatus() {
        authorizationStatus = MusicAuthorization.currentStatus
    }
    
    // MARK: - Playlists
    
    /// Fetches all playlists from the user's Apple Music library.
    func fetchUserPlaylists() async throws -> [Playlist] {
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
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
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
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
        
        // 2. Identify missing IDs that require remote lookup
        let missingIDs = trackIDs.filter { resolvedISRCs[$0] == nil }
        let songIDsToFetch = missingIDs.filter { !$0.hasPrefix("i.") }.map { MusicItemID($0) }
        
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
            if isrc == nil, let song = catalogSongsByID[track.id.rawValue] {
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
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
        let playlist = try await MusicLibrary.shared.createPlaylist(
            name: name,
            description: description
        )
        
        return playlist
    }
    
    // MARK: - Track Management
    
    /// Adds a song to a playlist.
    func addTrack(_ song: Song, to playlist: Playlist) async throws {
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
        _ = try await MusicLibrary.shared.add(song, to: playlist)
    }
    
    /// Adds multiple songs to a playlist in a single batch request to preserve order and optimize performance.
    func addTracks(_ songs: [Song], to playlist: Playlist) async throws {
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
        guard !songs.isEmpty else { return }
        
        let playlistId = playlist.id.rawValue
        let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists/\(playlistId)/tracks")!
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let trackData: [[String: String]] = songs.map { song in
            ["id": song.id.rawValue, "type": "songs"]
        }
        
        let body = ["data": trackData]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let request = MusicDataRequest(urlRequest: urlRequest)
        _ = try await request.response()
        
        print("[AppleMusic] Batch added \(songs.count) tracks to playlist \(playlist.name)")
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
        
        guard let uiImage = UIImage(data: data) else {
            return nil
        }
        
        // Compress as JPEG — start at 0.8 quality, reduce if over 256KB
        var quality: CGFloat = 0.8
        var jpegData = uiImage.jpegData(compressionQuality: quality)
        
        while let data = jpegData, data.count > 256_000, quality > 0.1 {
            quality -= 0.1
            jpegData = uiImage.jpegData(compressionQuality: quality)
        }
        
        guard let finalData = jpegData else {
            return nil
        }
        
        return finalData.base64EncodedString()
    }
    
    // MARK: - Catalog Search
    
    /// Searches the Apple Music catalog for a song by ISRC code.
    /// This is the primary matching strategy for cross-platform sync.
    func searchByISRC(_ isrc: String) async throws -> Song? {
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
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
        guard isAuthorized else {
            throw AppleMusicError.notAuthorized
        }
        
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
    case playlistNotFound
    case trackNotFound(isrc: String)
    case addTrackFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Apple Music access not authorized. Please grant access in Settings."
        case .playlistNotFound:
            return "The Apple Music playlist could not be found."
        case .trackNotFound(let isrc):
            return "No matching track found on Apple Music for ISRC: \(isrc)"
        case .addTrackFailed(let detail):
            return "Failed to add track to playlist: \(detail)"
        }
    }
}
