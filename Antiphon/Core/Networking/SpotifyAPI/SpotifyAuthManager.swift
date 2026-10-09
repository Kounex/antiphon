import Foundation
import AuthenticationServices
import CryptoKit
import Observation

/// Manages Spotify OAuth authentication and observable UI state.
///
/// Fully `@MainActor`-isolated: owns login/logout flows, user profile display,
/// and BYOK Client ID management. Does NOT manage token lifecycle for API calls —
/// that responsibility belongs to `SpotifyTokenProvider` (an actor that reads the
/// same Keychain tokens written here during login).
@MainActor
@Observable
final class SpotifyAuthManager: NSObject {
    
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
    
    private var codeVerifier: String?
    private var expectedState: String?
    private var authSession: ASWebAuthenticationSession?
    private weak var presentingAnchor: ASPresentationAnchor?
    
    // MARK: - Init
    
    override init() {
        super.init()
        isAuthenticated = KeychainManager.load(.spotifyRefreshToken) != nil
    }
    
    // MARK: - Public API
    
    /// Starts the Spotify OAuth PKCE login flow.
    func startLogin(presentingFrom anchor: ASPresentationAnchor) async throws {
        guard let clientId else {
            throw SpotifyAuthError.noClientId
        }
        
        self.presentingAnchor = anchor
        isAuthenticating = true
        authError = nil
        
        defer { isAuthenticating = false }
        
        let verifier = generateCodeVerifier()
        let challenge = generateCodeChallenge(from: verifier)
        self.codeVerifier = verifier

        let state = UUID().uuidString
        self.expectedState = state

        guard var components = URLComponents(string: AppConstants.Spotify.authURL) else {
            throw SpotifyAuthError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: AppConstants.Spotify.redirectURI),
            URLQueryItem(name: "scope", value: AppConstants.Spotify.scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state)
        ]
        
        guard let authURL = components.url else {
            throw SpotifyAuthError.invalidURL
        }
        
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
            guard session.start() else {
                continuation.resume(throwing: SpotifyAuthError.sessionStartFailed)
                return
            }
        }
        
        guard let callbackItems = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems,
              let code = callbackItems.first(where: { $0.name == "code" })?.value else {
            throw SpotifyAuthError.noAuthCode
        }

        guard callbackItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw SpotifyAuthError.invalidState
        }
        expectedState = nil
        
        let accessToken = try await exchangeCodeForTokens(code: code, verifier: verifier)
        await fetchUserProfile(accessToken: accessToken)
    }
    
    /// Logs out and clears all stored tokens.
    func logout() {
        KeychainManager.delete(.spotifyAccessToken)
        KeychainManager.delete(.spotifyRefreshToken)
        KeychainManager.delete(.spotifyTokenExpiry)
        isAuthenticated = false
        userProfile = nil
        authError = nil
    }
    
    /// Re-checks Keychain for auth state. Call after a background token refresh
    /// failure may have cleared tokens.
    func refreshAuthStatus() {
        isAuthenticated = KeychainManager.load(.spotifyRefreshToken) != nil
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
    
    // MARK: - Token Exchange (login-only, writes to Keychain for SpotifyTokenProvider)
    
    @discardableResult
    private func exchangeCodeForTokens(code: String, verifier: String) async throws -> String {
        guard let clientId else { throw SpotifyAuthError.noClientId }

        guard let tokenURL = URL(string: AppConstants.Spotify.tokenURL) else {
            throw SpotifyAuthError.invalidURL
        }
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        
        guard let body = SpotifyFormEncoder.encode([
            ("client_id", clientId),
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", AppConstants.Spotify.redirectURI),
            ("code_verifier", verifier)
        ]) else {
            throw SpotifyAuthError.invalidURL
        }
        request.httpBody = body
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw SpotifyAuthError.tokenExchangeFailed
        }
        
        let tokenResponse = try JSONDecoder().decode(SpotifyTokenResponse.self, from: data)
        
        try KeychainManager.save(tokenResponse.accessToken, for: .spotifyAccessToken)
        if let newRefresh = tokenResponse.refreshToken {
            try KeychainManager.save(newRefresh, for: .spotifyRefreshToken)
        }
        let expiry = Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn))
        try KeychainManager.save(String(expiry.timeIntervalSince1970), for: .spotifyTokenExpiry)
        isAuthenticated = true
        return tokenResponse.accessToken
    }
    
    // MARK: - User Profile
    
    private func fetchUserProfile(accessToken token: String) async {
        do {
            guard let url = SpotifyEndpoint.me.url() else { return }
            
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            
            let (data, _) = try await URLSession.shared.data(for: request)
            userProfile = try JSONDecoder().decode(SpotifyUserProfile.self, from: data)
        } catch {
            print("Failed to fetch Spotify profile: \(error)")
        }
    }
}

// MARK: - ASWebAuthenticationPresentationContextProviding

extension SpotifyAuthManager: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            if let presentingAnchor {
                return presentingAnchor
            }
            if let scene = UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
               let window = scene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
            return UIWindow()
        }
    }
}

// MARK: - Errors

enum SpotifyAuthError: LocalizedError {
    case noClientId
    case notAuthenticated
    case invalidURL
    case noAuthCode
    case invalidState
    case sessionStartFailed
    case tokenExchangeFailed
    case tokenRefreshFailed
    case unknown
    
    var errorDescription: String? {
        switch self {
        case .noClientId: return "No Spotify Client ID configured. Please add your Client ID in Settings."
        case .notAuthenticated: return "Not logged in to Spotify. Please connect your account."
        case .invalidURL: return "Failed to build authorization URL."
        case .noAuthCode: return "No authorization code received from Spotify."
        case .invalidState: return "Authentication state mismatch. Please try again."
        case .sessionStartFailed: return "Failed to start the login session. Please try again."
        case .tokenExchangeFailed: return "Failed to exchange authorization code for tokens."
        case .tokenRefreshFailed: return "Session expired. Please reconnect Spotify."
        case .unknown: return "An unknown error occurred during Spotify authentication."
        }
    }
}
