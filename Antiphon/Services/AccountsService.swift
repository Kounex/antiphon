import Foundation

/// What the UI needs to know about the signed-in accounts.
@MainActor
protocol AccountsService: AnyObject {
    var spotifyDisplayName: String? { get }
    var isSpotifyConnected: Bool { get }
}

extension SpotifyAuthManager: AccountsService {
    var spotifyDisplayName: String? { userProfile?.displayName }
    var isSpotifyConnected: Bool { isAuthenticated }
}

#if DEBUG
@MainActor
final class PreviewAccounts: AccountsService {
    var spotifyDisplayName: String? = "Maya Klein"
    var isSpotifyConnected = true
}
#endif
