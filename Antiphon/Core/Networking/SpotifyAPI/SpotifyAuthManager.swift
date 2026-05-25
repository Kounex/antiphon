import Foundation
import AuthenticationServices
import CryptoKit
import Observation

@Observable
final class SpotifyAuthManager: NSObject, @unchecked Sendable {
    
    // MARK: - Published State
    
    var isAuthenticated: Bool = false
    var userProfile: SpotifyUserProfile?
    var isAuthenticating: Bool = false
    var authError: String?
    
    /// The user-provided Spotify Client ID (BYOK model)
    var clientId: String? {
        get { KeychainManager.load(.spotifyClientId) }
        set {
            if let newValue {
                try? KeychainManager.save(newValue, for: .spotifyClientId)
            } else {
                KeychainManager.delete(.spotifyClientId)
            }
        }
    }
    
    // MARK: - Private State
    
    private var accessToken: String? {
        get { KeychainManager.load(.spotifyAccessToken) }
        set {
            if let newValue {
                try? KeychainManager.save(newValue, for: .spotifyAccessToken)
            } else {
                KeychainManager.delete(.spotifyAccessToken)
            }
        }
    }
    
    private var refreshToken: String? {
        get { KeychainManager.load(.spotifyRefreshToken) }
        set {
            if let newValue {
                try? KeychainManager.save(newValue, for: .spotifyRefreshToken)
            } else {
                KeychainManager.delete(.spotifyRefreshToken)
            }
        }
    }
    
    private var tokenExpiryDate: Date? {
        get {
            guard let string = KeychainManager.load(.spotifyTokenExpiry),
                  let interval = TimeInterval(string) else { return nil }
            return Date(timeIntervalSince1970: interval)
        }
        set {
            if let newValue {
                try? KeychainManager.save(String(newValue.timeIntervalSince1970), for: .spotifyTokenExpiry)
            } else {
                KeychainManager.delete(.spotifyTokenExpiry)
            }
        }
    }
    
    private var codeVerifier: String?
    private var authSession: ASWebAuthenticationSession?
    
    // MARK: - Init
    
    override init() {
        super.init()
        // Check if we have a valid refresh token
        isAuthenticated = refreshToken != nil
    }
    
    // MARK: - Public API
    
    /// Returns a valid access token, refreshing if necessary.
    func validAccessToken() async throws -> String {
        // If token is still valid (with 5-min buffer), return it
        if let token = accessToken,
           let expiry = tokenExpiryDate,
           expiry.timeIntervalSinceNow > 300 {
            return token
        }
        
        // Try to refresh
        guard let refresh = refreshToken else {
            throw SpotifyAuthError.notAuthenticated
        }
        
        return try await refreshAccessToken(using: refresh)
    }
    
    /// Starts the Spotify OAuth PKCE login flow.
    @MainActor
    func startLogin(presentingFrom anchor: ASPresentationAnchor) async throws {
        guard let clientId else {
            throw SpotifyAuthError.noClientId
        }
        
        isAuthenticating = true
        authError = nil
        
        defer { isAuthenticating = false }
        
        // Generate PKCE values
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        self.codeVerifier = verifier
        
        // Build authorization URL
        var components = URLComponents(string: AppConstants.Spotify.authURL)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: AppConstants.Spotify.redirectURI),
            URLQueryItem(name: "scope", value: AppConstants.Spotify.scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: UUID().uuidString)
        ]
        
        guard let authURL = components.url else {
            throw SpotifyAuthError.invalidURL
        }
        
        // Present the auth session
        let callbackURL = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let session = ASWebAuthenticationSession(
                url: authURL,
                callbackURLScheme: "antiphon"
            ) { url, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let url {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(throwing: SpotifyAuthError.unknown)
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
        
        // Extract authorization code
        guard let code = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "code" })?.value else {
            throw SpotifyAuthError.noAuthCode
        }
        
        // Exchange code for tokens
        try await exchangeCodeForTokens(code: code, verifier: verifier)
        
        // Fetch user profile
        await fetchUserProfile()
    }
    
    /// Logs out and clears all stored tokens.
    @MainActor
    func logout() {
        accessToken = nil
        refreshToken = nil
        tokenExpiryDate = nil
        isAuthenticated = false
        userProfile = nil
    }
    
    // MARK: - PKCE Helpers
    
    private func generateCodeVerifier() -> String {
        var buffer = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, &buffer)
        return Data(buffer).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    private func generateCodeChallenge(from verifier: String) -> String {
        let data = Data(verifier.utf8)
        let hash = SHA256.hash(data: data)
        return Data(hash).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    
    // MARK: - Token Exchange
    
    @MainActor
    private func exchangeCodeForTokens(code: String, verifier: String) async throws {
        guard let clientId else { throw SpotifyAuthError.noClientId }
        
        var request = URLRequest(url: URL(string: AppConstants.Spotify.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        let body = [
            "client_id=\(clientId)",
            "grant_type=authorization_code",
            "code=\(code)",
            "redirect_uri=\(AppConstants.Spotify.redirectURI)",
            "code_verifier=\(verifier)"
        ].joined(separator: "&")
        
        request.httpBody = body.data(using: .utf8)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpotifyAuthError.tokenExchangeFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        
        accessToken = tokenResponse.accessToken
        if let newRefresh = tokenResponse.refreshToken {
            refreshToken = newRefresh
        }
        tokenExpiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        isAuthenticated = true
    }
    
    @MainActor
    private func refreshAccessToken(using refresh: String) async throws -> String {
        guard let clientId else { throw SpotifyAuthError.noClientId }
        
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
            // Refresh failed — user needs to re-authenticate
            isAuthenticated = false
            throw SpotifyAuthError.tokenRefreshFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        
        accessToken = tokenResponse.accessToken
        if let newRefresh = tokenResponse.refreshToken {
            refreshToken = newRefresh
        }
        tokenExpiryDate = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        
        return tokenResponse.accessToken
    }
    
    // MARK: - User Profile
    
    @MainActor
    private func fetchUserProfile() async {
        do {
            let token = try await validAccessToken()
            guard let url = SpotifyEndpoint.me.url() else { return }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            userProfile = try JSONDecoder().decode(SpotifyUserProfile.self, from: data)
        } catch {
            // Non-critical — profile is nice-to-have
            print("Failed to fetch Spotify profile: \(error)")
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SpotifyAuthManager: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        ASPresentationAnchor()
    }
}

// MARK: - Errors

enum SpotifyAuthError: LocalizedError {
    case noClientId
    case notAuthenticated
    case invalidURL
    case noAuthCode
    case tokenExchangeFailed
    case tokenRefreshFailed
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .noClientId: return "No Spotify Client ID configured. Please add your Client ID in Settings."
        case .notAuthenticated: return "Not logged in to Spotify. Please connect your account."
        case .invalidURL: return "Failed to build authorization URL."
        case .noAuthCode: return "No authorization code received from Spotify."
        case .tokenExchangeFailed: return "Failed to exchange authorization code for tokens."
        case .tokenRefreshFailed: return "Session expired. Please reconnect Spotify."
        case .unknown: return "An unknown error occurred during Spotify authentication."
        }
    }
}
