import Foundation

/// Manages Spotify access token lifecycle: reads from Keychain, refreshes when
/// expired, writes updated tokens back.
///
/// This is an actor so concurrent callers (multiple API requests) are serialized
/// — only one refresh can happen at a time. It is fully self-contained: any code
/// that needs a Spotify token can create `SpotifyTokenProvider()` and call
/// `validAccessToken()`. The Keychain is the shared source of truth, so multiple
/// provider instances (foreground UI, background task, App Intent) all see the
/// same credentials without sharing mutable in-memory state.
actor SpotifyTokenProvider {

    func validAccessToken() async throws -> String {
        if let token = KeychainManager.load(.spotifyAccessToken),
           let expiryString = KeychainManager.load(.spotifyTokenExpiry),
           let interval = TimeInterval(expiryString),
           Date(timeIntervalSince1970: interval).timeIntervalSinceNow > 300 {
            return token
        }

        guard let refresh = KeychainManager.load(.spotifyRefreshToken) else {
            throw SpotifyAuthError.notAuthenticated
        }

        return try await refreshAccessToken(using: refresh)
    }

    // MARK: - Token Refresh

    private func refreshAccessToken(using refresh: String) async throws -> String {
        guard let clientId = KeychainManager.load(.spotifyClientId) else {
            throw SpotifyAuthError.noClientId
        }

        var request = URLRequest(url: URL(string: AppConstants.Spotify.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        let body = [
            "grant_type=refresh_token",
            "refresh_token=\(refresh)",
            "client_id=\(clientId)"
        ].joined(separator: "&")
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            KeychainManager.delete(.spotifyAccessToken)
            KeychainManager.delete(.spotifyRefreshToken)
            KeychainManager.delete(.spotifyTokenExpiry)
            throw SpotifyAuthError.tokenRefreshFailed
        }

        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)

        try? KeychainManager.save(tokenResponse.accessToken, for: .spotifyAccessToken)
        if let newRefresh = tokenResponse.refreshToken {
            try? KeychainManager.save(newRefresh, for: .spotifyRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try? KeychainManager.save(String(expiry.timeIntervalSince1970), for: .spotifyTokenExpiry)

        return tokenResponse.accessToken
    }
}
