import Foundation

/// App-wide constants for Antiphon, organized by feature area.
enum AppConstants {
    static let appName = "Antiphon"
    static let bundleId = "com.kounex.antiphon"

    /// Spotify OAuth and API configuration.
    enum Spotify {
        static let authURL = "https://accounts.spotify.com/authorize"
        static let tokenURL = "https://accounts.spotify.com/api/token"
        static let apiBaseURL = "https://api.spotify.com/v1"
        static let redirectURI = "antiphon://spotify-callback"
        static let scopes = "playlist-read-private playlist-read-collaborative playlist-modify-public playlist-modify-private user-library-read"
    }

    /// Background task identifiers.
    enum BackgroundTasks {
        static let playlistRefreshIdentifier = "com.antiphon.playlistRefresh"
    }

    /// Sync engine thresholds and defaults.
    enum Sync {
        /// Abort if more than this percentage of tracks would be removed.
        static let safetyThresholdPercentage: Double = 0.5
        static let defaultSyncIntervalMinutes: Int = 30
        /// Minimum interval between syncs (5 minutes).
        static let minimumSyncIntervalSeconds: TimeInterval = 300
    }
}
