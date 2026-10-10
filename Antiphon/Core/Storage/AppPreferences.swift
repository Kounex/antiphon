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
        static let newSeamRemovalPolicy = "newSeamRemovalPolicy"
        static let newSeamMonitoring = "newSeamMonitoring"
        static let monitorIntervalMinutes = "monitorIntervalMinutes"
        /// Written by the pre-redesign Settings screen.
        static let legacyInterval = "syncIntervalMinutes"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
    }

    // MARK: - Matching

    /// Matches at or above this confidence are added without asking.
    var autoAddThreshold: Int {
        get { defaults.object(forKey: Key.autoAddThreshold) as? Int ?? ConfidencePolicy.defaultAutoAddThreshold }
        set { defaults.set(newValue, forKey: Key.autoAddThreshold) }
    }

    /// Off until the review queue ships (D7b). While off, matches from 60%
    /// up are added automatically, exactly as before the redesign.
    var reviewQueueEnabled: Bool {
        get { defaults.bool(forKey: Key.reviewQueueEnabled) }
        set { defaults.set(newValue, forKey: Key.reviewQueueEnabled) }
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

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: Key.hasCompletedOnboarding) }
        set { defaults.set(newValue, forKey: Key.hasCompletedOnboarding) }
    }
}
