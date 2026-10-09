import Foundation

/// A client for making authenticated requests to the Spotify Web API.
///
/// Takes a `SpotifyTokenProvider` (actor) for token lifecycle instead of
/// `SpotifyAuthManager` — keeping API access decoupled from UI auth state.
actor SpotifyAPIClient {
    
    private let tokenProvider: SpotifyTokenProvider
    private let session: URLSession
    private let decoder: JSONDecoder
    
    init(tokenProvider: SpotifyTokenProvider = SpotifyTokenProvider()) {
        self.tokenProvider = tokenProvider
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
    
    /// Fetches the current user's playlists whose items can be read and
    /// written: owned or collaborative. Since February 2026 Spotify returns
    /// 403 for item access on playlists the user only follows.
    func getEditablePlaylists() async throws -> [SpotifyPlaylist] {
        async let user = getCurrentUser()
        async let playlists = getAllPlaylists()
        let userId = try await user.id
        return try await playlists.filter { $0.isEditable(byUserId: userId) }
    }

    /// Fetches all tracks in a playlist (handles pagination).
    ///
    /// Podcast episode items (`type == "episode"`) are dropped: they can't be
    /// matched or added on Apple Music, and their different JSON shape must
    /// never poison the sync pipeline. `market` defaults to nil so tracks are
    /// returned without availability filtering for one specific country.
    func getPlaylistTracks(playlistId: String, market: String? = nil) async throws -> [SpotifyPlaylistItem] {
        var allItems: [SpotifyPlaylistItem] = []
        var offset = 0
        let limit = 50

        while true {
            let page: SpotifyPagingObject<SpotifyPlaylistItem> = try await request(
                endpoint: .playlistTracks(playlistId: playlistId, limit: limit, offset: offset, market: market)
            )
            allItems.append(contentsOf: page.items.filter { $0.track?.type != "episode" })

            if page.next == nil { break }
            offset += limit

            // Small delay between pages to avoid rate limiting
            try await Task.sleep(for: .milliseconds(100))
        }

        return allItems
    }
    
    /// Creates a new playlist for the current user.
    func createPlaylist(
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
        return try await request(endpoint: .createPlaylist, body: body)
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
                items: batch.map { SpotifyTrackReference(uri: $0) },
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
    func searchByISRC(_ isrc: String, market: String? = nil) async throws -> SpotifyTrack? {
        let response: SpotifySearchResponse = try await request(
            endpoint: .searchByISRC(isrc: isrc, market: market)
        )
        return response.tracks?.items.first
    }
    
    /// Searches for tracks by query string. Spotify caps `limit` at 10 for
    /// Development Mode apps (February 2026), so larger values are clamped.
    func search(query: String, type: String = "track", market: String? = nil, limit: Int = 10) async throws -> [SpotifyTrack] {
        let response: SpotifySearchResponse = try await request(
            endpoint: .searchByQuery(query: query, type: type, market: market, limit: min(limit, 10))
        )
        return response.tracks?.items ?? []
    }
    
    // MARK: - Playlist Image
    
    /// Uploads a custom cover image to a Spotify playlist.
    /// The image must be a Base64-encoded JPEG string (max ~256KB).
    func uploadPlaylistImage(playlistId: String, base64JPEG: String) async throws {
        let endpoint = SpotifyEndpoint.uploadPlaylistImage(playlistId: playlistId)
        let token = try await tokenProvider.validAccessToken()

        func buildUploadRequest(_ token: String) throws -> URLRequest {
            guard let url = endpoint.url() else {
                throw SpotifyAPIError.invalidURL
            }
            var urlRequest = URLRequest(url: url)
            urlRequest.httpMethod = endpoint.httpMethod
            urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            urlRequest.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
            urlRequest.httpBody = base64JPEG.data(using: .utf8)
            return urlRequest
        }

        do {
            try await executeWithRetryNoContent(buildUploadRequest(token))
        } catch SpotifyAPIError.httpError(let statusCode, _) where statusCode == 401 {
            let freshToken = try await tokenProvider.forceRefreshedToken(rejecting: token)
            try await executeWithRetryNoContent(buildUploadRequest(freshToken))
        }

        print("[Spotify] Playlist image uploaded successfully for \(playlistId)")
    }
    
    // MARK: - Generic Request

    private func request<T: Decodable>(endpoint: SpotifyEndpoint) async throws -> T {
        let token = try await tokenProvider.validAccessToken()
        do {
            return try await executeWithRetry(buildRequest(endpoint: endpoint, token: token))
        } catch SpotifyAPIError.httpError(let statusCode, _) where statusCode == 401 {
            // Spotify rejected a token the local expiry still trusted (clock
            // skew, revocation). Force one refresh and retry once.
            let freshToken = try await tokenProvider.forceRefreshedToken(rejecting: token)
            return try await executeWithRetry(buildRequest(endpoint: endpoint, token: freshToken))
        }
    }

    private func request<T: Decodable, B: Encodable>(endpoint: SpotifyEndpoint, body: B) async throws -> T {
        let token = try await tokenProvider.validAccessToken()
        do {
            return try await executeWithRetry(buildRequest(endpoint: endpoint, token: token, body: body))
        } catch SpotifyAPIError.httpError(let statusCode, _) where statusCode == 401 {
            let freshToken = try await tokenProvider.forceRefreshedToken(rejecting: token)
            return try await executeWithRetry(buildRequest(endpoint: endpoint, token: freshToken, body: body))
        }
    }

    private func buildRequest(endpoint: SpotifyEndpoint, token: String) throws -> URLRequest {
        guard let url = endpoint.url() else {
            throw SpotifyAPIError.invalidURL
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = endpoint.httpMethod
        urlRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return urlRequest
    }

    private func buildRequest<B: Encodable>(endpoint: SpotifyEndpoint, token: String, body: B) throws -> URLRequest {
        var urlRequest = try buildRequest(endpoint: endpoint, token: token)
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
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

    /// Same retry pipeline as `executeWithRetry` for requests with no decodable body.
    private func executeWithRetryNoContent(_ request: URLRequest, retryCount: Int = 0) async throws {
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
            return try await executeWithRetryNoContent(request, retryCount: retryCount + 1)
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw SpotifyAPIError.httpError(statusCode: httpResponse.statusCode, body: String(data: data, encoding: .utf8))
        }
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
