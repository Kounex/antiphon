import Foundation

/// App-wide settings, stored in `UserDefaults`.
///
/// Not `@Observable`: view models read it and publish their own state.
/// Safe to create anywhere, including background tasks.
final class AppPreferences: @unchecked Sendable {
    // @unchecked: UserDefaults is thread-safe and this class holds no other state.

    static let shared = AppPreferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private enum Key {
        static let autoAddThreshold = "autoAddThreshold"
        static let reviewQueueEnabled = "reviewQueueEnabled"
        static let acceptRemasters = "acceptRemasters"
        static let releaseChoice = "releaseChoice"
        static let newSeamRemovalPolicy = "newSeamRemovalPolicy"
        static let newSeamMonitoring = "newSeamMonitoring"
        static let monitorIntervalMinutes = "monitorIntervalMinutes"
        /// Written by the pre-redesign Settings screen.
        static let legacyInterval = "syncIntervalMinutes"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let recentSearches = "recentSearches"
        static let showsCollaboratorNames = "showsCollaboratorNames"
        static let explicitPreference = "explicitPreference"
        static let allowLive = "allowLive"
        static let allowRadioEdits = "allowRadioEdits"
        static let recheckCadence = "recheckCadence"
        static let wifiOnly = "monitorWiFiOnly"
        static let pauseInLowPower = "monitorPauseInLowPower"
        static let quietHours = "monitorQuietHours"
        static let notifyDecide = "notifyDecide"
        static let notifyBreaks = "notifyBreaks"
        static let notifyNewTracks = "notifyNewTracks"
        static let weeklyDigest = "notifyWeeklyDigest"
        static let spotifySignedInAt = "spotifySignedInAt"
    }

    // MARK: - Matching

    /// Matches at or above this confidence are added without asking.
    var autoAddThreshold: Int {
        get { defaults.object(forKey: Key.autoAddThreshold) as? Int ?? ConfidencePolicy.defaultAutoAddThreshold }
        set { defaults.set(newValue, forKey: Key.autoAddThreshold) }
    }

    /// On since the review queue shipped (M5). While off, matches from 60%
    /// up are added automatically, exactly as before the redesign.
    var reviewQueueEnabled: Bool {
        get { defaults.object(forKey: Key.reviewQueueEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.reviewQueueEnabled) }
    }

    /// "Prefer remasters" from a track's match detail.
    var acceptRemasters: Bool {
        get { defaults.bool(forKey: Key.acceptRemasters) }
        set { defaults.set(newValue, forKey: Key.acceptRemasters) }
    }

    /// Which album a match comes from: the source's, or the original.
    var releaseChoice: ReleaseChoice {
        get { defaults.string(forKey: Key.releaseChoice).flatMap(ReleaseChoice.init) ?? .sourceAlbum }
        set { defaults.set(newValue.rawValue, forKey: Key.releaseChoice) }
    }

    var explicitPreference: ExplicitPreference {
        get { defaults.string(forKey: Key.explicitPreference).flatMap(ExplicitPreference.init) ?? .sameAsSource }
        set { defaults.set(newValue.rawValue, forKey: Key.explicitPreference) }
    }

    /// Off: live versions are never used unless the source is live.
    var allowLive: Bool {
        get { defaults.bool(forKey: Key.allowLive) }
        set { defaults.set(newValue, forKey: Key.allowLive) }
    }

    var allowRadioEdits: Bool {
        get { defaults.bool(forKey: Key.allowRadioEdits) }
        set { defaults.set(newValue, forKey: Key.allowRadioEdits) }
    }

    /// How often tracks that weren't found are looked up again.
    var recheckCadence: RecheckCadence {
        get { defaults.string(forKey: Key.recheckCadence).flatMap(RecheckCadence.init) ?? .weekly }
        set { defaults.set(newValue.rawValue, forKey: Key.recheckCadence) }
    }

    var versionPreferences: VersionPreferences {
        VersionPreferences(acceptRemasters: acceptRemasters, release: releaseChoice, explicit: explicitPreference,
                           allowLive: allowLive, allowRadioEdits: allowRadioEdits)
    }

    var confidencePolicy: ConfidencePolicy {
        ConfidencePolicy(autoAddThreshold: reviewQueueEnabled ? autoAddThreshold : ConfidencePolicy.reviewFloor)
    }

    // MARK: - New seam defaults

    var newSeamRemovalPolicy: RemovalPolicy {
        get { defaults.string(forKey: Key.newSeamRemovalPolicy).flatMap(RemovalPolicy.init) ?? .keep }
        set { defaults.set(newValue.rawValue, forKey: Key.newSeamRemovalPolicy) }
    }

    var newSeamMonitoring: Bool {
        get { defaults.object(forKey: Key.newSeamMonitoring) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.newSeamMonitoring) }
    }

    // MARK: - Monitoring

    /// Requested minutes between checks. iOS decides the exact moment.
    var monitorIntervalMinutes: Int {
        get {
            defaults.object(forKey: Key.monitorIntervalMinutes) as? Int
                ?? (defaults.object(forKey: Key.legacyInterval) as? Int)
                ?? 15
        }
        set { defaults.set(newValue, forKey: Key.monitorIntervalMinutes) }
    }

    // MARK: - Monitoring gates

    var wifiOnly: Bool {
        get { defaults.bool(forKey: Key.wifiOnly) }
        set { defaults.set(newValue, forKey: Key.wifiOnly) }
    }

    var pauseInLowPower: Bool {
        get { defaults.object(forKey: Key.pauseInLowPower) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.pauseInLowPower) }
    }

    /// `nil`: no quiet hours.
    var quietHours: MonitorGates.QuietHours? {
        get { defaults.data(forKey: Key.quietHours).flatMap { try? JSONDecoder().decode(MonitorGates.QuietHours.self, from: $0) } }
        set {
            if let newValue, let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Key.quietHours)
            } else {
                defaults.removeObject(forKey: Key.quietHours)
            }
        }
    }

    var monitorGates: MonitorGates.Settings {
        MonitorGates.Settings(wifiOnly: wifiOnly, pauseInLowPower: pauseInLowPower, quietHours: quietHours)
    }

    // MARK: - Notifications

    /// Close matches and removals waiting for an answer.
    var notifyDecide: Bool {
        get { defaults.object(forKey: Key.notifyDecide) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notifyDecide) }
    }

    /// Sign-ins, deleted playlists, failed syncs.
    var notifyBreaks: Bool {
        get { defaults.object(forKey: Key.notifyBreaks) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.notifyBreaks) }
    }

    var notifyNewTracks: MonitorNotifications.NewTracks {
        get { defaults.string(forKey: Key.notifyNewTracks).flatMap(MonitorNotifications.NewTracks.init) ?? .dailySummary }
        set { defaults.set(newValue.rawValue, forKey: Key.notifyNewTracks) }
    }

    /// Sundays at 10:00.
    var weeklyDigest: Bool {
        get { defaults.bool(forKey: Key.weeklyDigest) }
        set { defaults.set(newValue, forKey: Key.weeklyDigest) }
    }

    var notificationPreferences: MonitorNotifications.Preferences {
        MonitorNotifications.Preferences(decide: notifyDecide, breaks: notifyBreaks, newTracks: notifyNewTracks)
    }

    // MARK: - Accounts

    /// Written when a Spotify sign-in completes.
    var spotifySignedInAt: Date? {
        get { defaults.object(forKey: Key.spotifySignedInAt) as? Date }
        set { defaults.set(newValue, forKey: Key.spotifySignedInAt) }
    }

    // MARK: - Search

    /// Newest first; kept on this device only.
    var recentSearches: [String] {
        get { defaults.stringArray(forKey: Key.recentSearches) ?? [] }
        set { defaults.set(newValue, forKey: Key.recentSearches) }
    }

    /// Collaborative playlists show who added each track by name. Off by
    /// default: it costs a request per collaborator.
    var showsCollaboratorNames: Bool {
        get { defaults.bool(forKey: Key.showsCollaboratorNames) }
        set { defaults.set(newValue, forKey: Key.showsCollaboratorNames) }
    }

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }
}
