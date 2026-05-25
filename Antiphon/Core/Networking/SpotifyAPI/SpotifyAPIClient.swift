import Foundation

/// A client for making authenticated requests to the Spotify Web API.
actor SpotifyAPIClient {
    
    private let authManager: SpotifyAuthManager
    private let session: URLSession
    private let decoder: JSONDecoder
    
    init(authManager: SpotifyAuthManager) {
        self.authManager = authManager
        self.session = URLSession.shared
        self.decoder = JSONDecoder()
    }
    
    // MARK: - User
    
    /// Fetches the current user's profile.
    func getCurrentUser() async throws -> SpotifyUserProfile {
        return try await request(endpoint: .me)
    }
    
    // MARK: - Playlists
    
    /// Fetches all of the current user's playlists (handles pagination).
    func getAllPlaylists() async throws -> [SpotifyPlaylist] {
        var allPlaylists: [SpotifyPlaylist] = []
        var offset = 0
        let limit = 50
        
        while true {
            let page: SpotifyPagingObject<SpotifyPlaylist> = try await request(
                endpoint: .myPlaylists(limit: limit, offset: offset)
            )
            allPlaylists.append(contentsOf: page.items)
            
            if page.next == nil { break }
            offset += limit
        }
        
        return allPlaylists
    }
    
    /// Fetches all tracks in a playlist (handles pagination).
    func getPlaylistTracks(playlistId: String, market: String = "US") async throws -> [SpotifyPlaylistItem] {
        var allItems: [SpotifyPlaylistItem] = []
        var offset = 0
        let limit = 50
        
        while true {
            let page: SpotifyPagingObject<SpotifyPlaylistItem> = try await request(
                endpoint: .playlistTracks(playlistId: playlistId, limit: limit, offset: offset, market: market)
            )
            allItems.append(contentsOf: page.items)
            
            if page.next == nil { break }
            offset += limit
            
            // Small delay between pages to avoid rate limiting
            try await Task.sleep(for: .milliseconds(100))
        }
        
        return allItems
    }
    
    /// Creates a new playlist for the given user.
    func createPlaylist(
        userId: String,
        name: String,
        description: String? = nil,
        isPublic: Bool = false
    ) async throws -> SpotifyPlaylist {
        let body = SpotifyCreatePlaylistRequest(
            name: name,
            description: description,
            isPublic: isPublic,
            collaborative: false
        )
        return try await request(endpoint: .createPlaylist(userId: userId), body: body)
    }
    
    /// Adds tracks to a playlist (handles batches of 100).
    func addTracksToPlaylist(playlistId: String, trackUris: [String]) async throws {
        // Spotify allows max 100 URIs per request
        for batch in trackUris.chunked(into: 100) {
            let body = SpotifyAddTracksRequest(uris: batch, position: nil)
            let _: SpotifySnapshotResponse = try await request(
                endpoint: .addTracks(playlistId: playlistId),
                body: body
            )
            
            if batch.count == 100 {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    
    /// Removes tracks from a playlist (handles batches of 100).
    func removeTracksFromPlaylist(playlistId: String, trackUris: [String]) async throws {
        for batch in trackUris.chunked(into: 100) {
            let body = SpotifyRemoveTracksRequest(
                tracks: batch.map { SpotifyTrackReference(uri: $0) },
                snapshotId: nil
            )
            let _: SpotifySnapshotResponse = try await request(
                endpoint: .removeTracks(playlistId: playlistId),
                body: body
            )
            
            if batch.count == 100 {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }
    
    // MARK: - Search
    
    /// Searches for a track by ISRC code.
    func searchByISRC(_ isrc: String, market: String = "US") async throws -> SpotifyTrack? {
        let response: SpotifySearchResponse = try await request(
            endpoint: .searchByISRC(isrc: isrc, market: market)
        )
        return response.tracks?.items.first
    }
    
    /// Searches for tracks by query string.
    func search(query: String, type: String = "track", market: String? = "US", limit: Int = 10) async throws -> [SpotifyTrack] {
        let response: SpotifySearchResponse = try await request(
            endpoint: .searchByQuery(query: query, type: type, market: market, limit: limit)
        )
        return response.tracks?.items ?? []
    }
    
    // MARK: - Playlist Image
    
    /// Uploads a custom cover image to a Spotify playlist.
    /// The image must be a Base64-encoded JPEG string (max ~256KB).
    func uploadPlaylistImage(playlistId: String, base64JPEG: String) async throws {
        let token = try await authManager.validAccessToken()
        let endpoint = SpotifyEndpoint.uploadPlaylistImage(playlistId: playlistId)
        guard let url = endpoint.url() else {
            throw SpotifyAPIError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = endpoint.httpMethod
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = base64JPEG.data(using: .utf8)
        
        let (_, response) = try await session.data(for: urlRequest)
        
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw SpotifyAPIError.httpError(statusCode: statusCode, body: "Failed to upload playlist image")
        }
        
        print("[Spotify] Playlist image uploaded successfully for \(playlistId)")
    }
    
    // MARK: - Generic Request
    
    private func request<T: Decodable>(endpoint: SpotifyEndpoint) async throws -> T {
        let token = try await authManager.validAccessToken()
        guard let url = endpoint.url() else {
            throw SpotifyAPIError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = endpoint.httpMethod
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        
        return try await executeWithRetry(urlRequest)
    }
    
    private func request<T: Decodable, B: Encodable>(endpoint: SpotifyEndpoint, body: B) async throws -> T {
        let token = try await authManager.validAccessToken()
        guard let url = endpoint.url() else {
            throw SpotifyAPIError.invalidURL
        }
        
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = endpoint.httpMethod
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        
        return try await executeWithRetry(urlRequest)
    }
    
    private func executeWithRetry<T: Decodable>(_ request: URLRequest, retryCount: Int = 0) async throws -> T {
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SpotifyAPIError.invalidResponse
        }
        
        // Handle rate limiting
        if httpResponse.statusCode == 429 {
            let retryAfter = httpResponse.value(forHTTPHeaderField: "Retry-After")
                .flatMap(TimeInterval.init) ?? 5.0
            
            guard retryCount < 3 else {
                throw SpotifyAPIError.rateLimited
            }
            
            try await Task.sleep(for: .seconds(retryAfter))
            return try await executeWithRetry(request, retryCount: retryCount + 1)
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw SpotifyAPIError.httpError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }
        
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - Errors

enum SpotifyAPIError: LocalizedError {
    case invalidURL
    case invalidResponse
    case rateLimited
    case httpError(statusCode: Int, body: String?)
    
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid Spotify API URL"
        case .invalidResponse: return "Invalid response from Spotify"
        case .rateLimited: return "Spotify API rate limit exceeded. Please try again later."
        case .httpError(let code, let body): return "Spotify API error (\(code)): \(body ?? "Unknown")"
        }
    }
}

// MARK: - Array Extension for Chunking

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
