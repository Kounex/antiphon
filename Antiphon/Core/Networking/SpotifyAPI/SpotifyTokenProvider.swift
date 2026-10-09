import Foundation

/// Encodes OAuth token-endpoint parameters as a standards-compliant
/// `application/x-www-form-urlencoded` body. Raw string interpolation is not
/// safe here: token formats are server-controlled, and a `+`, `&`, or `=` in a
/// future token would silently corrupt the payload.
enum SpotifyFormEncoder {
    static func encode(_ params: [(String, String)]) -> Data? {
        var components = URLComponents()
        components.queryItems = params.map { URLQueryItem(name: $0.0, value: $0.1) }
        // percentEncodedQuery leaves "+" literal in values, but form decoders
        // read a literal "+" as a space — encode it explicitly.
        let query = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return query?.data(using: .utf8)
    }
}

/// Process-wide gate that serializes token refreshes across ALL
/// `SpotifyTokenProvider` instances (UI sync, background task, App Intent,
/// picker views each create their own). Without it, two instances refreshing
/// concurrently near expiry both POST the same refresh token; Spotify rotates
/// refresh tokens, so the loser gets `400 invalid_grant` — and the error
/// handling then deletes every credential from the Keychain, silently signing
/// the user out.
private actor SpotifyRefreshGate {
    private var inFlight: Task<String, Error>?

    func refresh(_ operation: @escaping @Sendable () async throws -> String) async throws -> String {
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task { try await operation() }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }
}

/// Manages Spotify access token lifecycle: reads from Keychain, refreshes when
/// expired, writes updated tokens back.
///
/// This is an actor so concurrent callers (multiple API requests) are serialized
/// — only one refresh can happen at a time. It is fully self-contained: any code
/// that needs a Spotify token can create `SpotifyTokenProvider()` and call
/// `validAccessToken()`. The Keychain is the shared source of truth, so multiple
/// provider instances (foreground UI, background task, App Intent) all see the
/// same credentials without sharing mutable in-memory state. Refreshes are
/// additionally serialized process-wide via `SpotifyRefreshGate`, so separate
/// instances can never trigger Spotify's refresh-token rotation race.
actor SpotifyTokenProvider {

    private static let refreshGate = SpotifyRefreshGate()

    func validAccessToken() async throws -> String {
        if let token = Self.cachedValidToken() {
            return token
        }

        return try await Self.refreshGate.refresh {
            // Double-checked: another instance may have just refreshed while we
            // waited on the gate — reuse its token instead of POSTing again.
            if let token = Self.cachedValidToken() {
                return token
            }
            guard let refresh = KeychainManager.load(.spotifyRefreshToken) else {
                throw SpotifyAuthError.notAuthenticated
            }
            return try await Self.performTokenRefresh(using: refresh)
        }
    }

    /// Forces a token refresh, treating `rejectedToken` as invalid even though
    /// the cached expiry still trusts it. Used by the API client's 401
    /// recovery. If another instance already refreshed while we waited on the
    /// gate, the cached token will differ from the rejected one and is reused.
    func forceRefreshedToken(rejecting rejectedToken: String) async throws -> String {
        // Drop the rejected token up front so no other caller is handed a
        // credential Spotify has already refused while the refresh is in flight.
        KeychainManager.delete(.spotifyAccessToken)
        KeychainManager.delete(.spotifyTokenExpiry)

        return try await Self.refreshGate.refresh {
            if let token = Self.cachedValidToken(), token != rejectedToken {
                return token
            }
            guard let refresh = KeychainManager.load(.spotifyRefreshToken) else {
                throw SpotifyAuthError.notAuthenticated
            }
            return try await Self.performTokenRefresh(using: refresh)
        }
    }

    // MARK: - Token Refresh

    private static func cachedValidToken() -> String? {
        guard let token = KeychainManager.load(.spotifyAccessToken),
              let expiryString = KeychainManager.load(.spotifyTokenExpiry),
              let interval = TimeInterval(expiryString),
              Date(timeIntervalSince1970: interval).timeIntervalSinceNow > 300 else {
            return nil
        }
        return token
    }

    private static func performTokenRefresh(using refresh: String) async throws -> String {
        guard let clientId = KeychainManager.load(.spotifyClientId) else {
            throw SpotifyAuthError.noClientId
        }

        guard let tokenURL = URL(string: AppConstants.Spotify.tokenURL) else {
            throw SpotifyAuthError.invalidURL
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        guard let body = SpotifyFormEncoder.encode([
            ("grant_type", "refresh_token"),
            ("refresh_token", refresh),
            ("client_id", clientId)
        ]) else {
            throw SpotifyAuthError.invalidURL
        }
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            // Only a 400 (invalid_grant / revoked authorization) justifies
            // clearing credentials; transient server errors must not force a re-login.
            if (response as? HTTPURLResponse)?.statusCode == 400 {
                KeychainManager.delete(.spotifyAccessToken)
                KeychainManager.delete(.spotifyRefreshToken)
                KeychainManager.delete(.spotifyTokenExpiry)
            }
            throw SpotifyAuthError.tokenRefreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)

        // The refresh POST outlives its callers (gate tasks aren't cancelled
        // when a caller is). A logout or Reset All Data landing mid-POST would
        // otherwise have these stale credentials re-populate a wiped Keychain —
        // only persist if our refresh token is still the stored one.
        guard KeychainManager.load(.spotifyRefreshToken) == refresh else {
            throw SpotifyAuthError.tokenRefreshFailed
        }

        try KeychainManager.save(tokenResponse.accessToken, for: .spotifyAccessToken)
        if let newRefresh = tokenResponse.refreshToken {
            try KeychainManager.save(newRefresh, for: .spotifyRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try KeychainManager.save(String(expiry.timeIntervalSince1970), for: .spotifyTokenExpiry)

        return tokenResponse.accessToken
    }
}
