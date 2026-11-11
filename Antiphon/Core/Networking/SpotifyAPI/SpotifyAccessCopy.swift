import Foundation

/// What a Spotify error means, in words the person can act on, with
/// Spotify's own message quoted when it sent one.
///
/// A 403 on a development-mode app usually isn't a sign-out: sign-in works
/// for anyone, but Spotify refuses every API call unless the app's owner has
/// Premium and has added the account under Users Management.
enum SpotifyAccessCopy {
    static let refused = "Spotify refused this account for this client ID. "
        + "Whoever created the Spotify app needs Premium and has to add your Spotify account "
        + "(its email address) under Users Management on developer.spotify.com. Then connect again."

    static func message(for error: any Error) -> String {
        switch error {
        case SpotifyAPIError.httpError(403, let body):
            return quoted(refused, spotifyMessage(fromBody: body))
        case SpotifyAPIError.httpError(401, _), SpotifyAuthError.notAuthenticated, SpotifyAuthError.tokenRefreshFailed:
            return "Spotify signed you out. Connect again in Settings › Spotify."
        case SpotifyAuthError.noClientId:
            return "Add your Spotify client ID in Settings › Spotify, then connect."
        case SpotifyAPIError.rateLimited, SpotifyAuthError.refreshUnavailable:
            return "Spotify is busy. Try again in a minute."
        case SpotifyAPIError.httpError(let code, let body):
            return quoted("Spotify answered with an error (\(code)). Try again in a few minutes.", spotifyMessage(fromBody: body))
        case let decoding as DecodingError:
            return "Spotify sent something Antiphon couldn't read (\(field(of: decoding)))."
        case let url as URLError where [.notConnectedToInternet, .networkConnectionLost, .dataNotAllowed].contains(url.code):
            return "You're offline. Connect to the internet and try again."
        default:
            return error.localizedDescription
        }
    }

    /// Spotify refused the account (as opposed to signing it out).
    static func isRefused(_ error: any Error) -> Bool {
        if case SpotifyAPIError.httpError(403, _) = error { return true }
        return false
    }

    /// Spotify's own words: `error.message` from a JSON error body, or a
    /// short plain-text body (what a development-mode 403 sends). HTML and
    /// long bodies are left out.
    static func spotifyMessage(fromBody body: String?) -> String? {
        struct Envelope: Decodable {
            struct Inner: Decodable { let message: String? }
            let error: Inner
        }
        guard let text = body?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        if let message = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)).error.message {
            return message.isEmpty ? nil : message
        }
        guard !text.hasPrefix("<"), !text.hasPrefix("{"), text.count <= 300 else { return nil }
        return text
    }

    private static func quoted(_ text: String, _ spotify: String?) -> String {
        guard let spotify else { return text }
        return "\(text)\n\nSpotify said: “\(spotify)”"
    }

    /// The JSON path that didn't decode, e.g. `items.3.snapshot_id`.
    private static func field(of error: DecodingError) -> String {
        let path: [any CodingKey]
        let missing: String?
        switch error {
        case .keyNotFound(let key, let context): path = context.codingPath; missing = key.stringValue
        case .valueNotFound(_, let context), .typeMismatch(_, let context), .dataCorrupted(let context):
            path = context.codingPath; missing = nil
        @unknown default: return "unknown field"
        }
        let parts = path.map { $0.intValue.map(String.init) ?? $0.stringValue } + [missing].compactMap { $0 }
        return parts.isEmpty ? "the reply" : parts.joined(separator: ".")
    }
}
