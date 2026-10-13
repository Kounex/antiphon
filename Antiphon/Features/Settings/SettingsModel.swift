import Foundation
import MusicKit
import Observation
import UserNotifications

/// Apple Music as Settings shows it.
struct AppleMusicAccount: Equatable, Sendable {
    enum Access: Equatable, Sendable { case allowed, denied, notAsked, restricted }
    var access: Access
    /// "Germany store".
    var storefront: String?
    /// Can add catalog songs to the library (needs a subscription).
    var hasSubscription: Bool?

    var statusText: String {
        switch access {
        case .allowed: "Connected"
        case .denied: "Not allowed"
        case .notAsked: "Not connected"
        case .restricted: "Restricted"
        }
    }
}

protocol AppleMusicAccountReader: Sendable {
    func read() async -> AppleMusicAccount
}

struct LiveAppleMusicAccountReader: AppleMusicAccountReader {
    func read() async -> AppleMusicAccount {
        let access: AppleMusicAccount.Access = switch MusicAuthorization.currentStatus {
        case .authorized: .allowed
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notAsked
        @unknown default: .notAsked
        }
        guard access == .allowed else { return AppleMusicAccount(access: access) }
        let code = try? await MusicDataRequest.currentCountryCode
        let country = code.flatMap { Locale.current.localizedString(forRegionCode: $0.uppercased()) }
        var subscription: Bool?
        for await status in MusicSubscription.subscriptionUpdates {
            subscription = status.canPlayCatalogContent
            break
        }
        return AppleMusicAccount(access: access, storefront: country.map { "\($0) store" }, hasSubscription: subscription)
    }
}

#if DEBUG
struct PreviewAppleMusicAccountReader: AppleMusicAccountReader {
    var account = AppleMusicAccount(access: .allowed, storefront: "Germany store", hasSubscription: true)
    func read() async -> AppleMusicAccount { account }
}
#endif

/// Settings: accounts, the sync defaults and Antiphon itself. Every choice
/// is written to `AppPreferences` as it changes.
@MainActor
@Observable
final class SettingsModel {
    private(set) var usage: AccountUsage = .empty
    private(set) var appleMusic = AppleMusicAccount(access: .notAsked)
    private(set) var confidences: [Int] = []
    private(set) var exportURL: URL?
    private(set) var notificationStatus: UNAuthorizationStatus = .notDetermined

    // Defaults for new seams
    var newSeamRemoval: RemovalPolicy { didSet { preferences.newSeamRemovalPolicy = newSeamRemoval } }
    var newSeamMonitoring: Bool { didSet { preferences.newSeamMonitoring = newSeamMonitoring } }

    // Matching
    var threshold: Int { didSet { preferences.autoAddThreshold = threshold } }
    var explicit: ExplicitPreference { didSet { preferences.explicitPreference = explicit } }
    var preferOriginal: Bool { didSet { preferences.acceptRemasters = !preferOriginal } }
    var neverLive: Bool { didSet { preferences.allowLive = !neverLive } }
    var allowRadioEdits: Bool { didSet { preferences.allowRadioEdits = allowRadioEdits } }
    var release: ReleaseChoice { didSet { preferences.releaseChoice = release } }
    var recheck: RecheckCadence { didSet { preferences.recheckCadence = recheck } }

    // Monitoring
    var interval: Int { didSet { preferences.monitorIntervalMinutes = interval } }
    var wifiOnly: Bool { didSet { preferences.wifiOnly = wifiOnly } }
    var removeInBackground: Bool { didSet { preferences.removeInBackground = removeInBackground } }
    var pauseInLowPower: Bool { didSet { preferences.pauseInLowPower = pauseInLowPower } }
    var quietHours: MonitorGates.QuietHours? { didSet { preferences.quietHours = quietHours } }

    // Notifications
    var notifyDecide: Bool { didSet { preferences.notifyDecide = notifyDecide; askIfNeeded(notifyDecide) } }
    var notifyBreaks: Bool { didSet { preferences.notifyBreaks = notifyBreaks; askIfNeeded(notifyBreaks) } }
    var notifyNewTracks: MonitorNotifications.NewTracks {
        didSet { preferences.notifyNewTracks = notifyNewTracks; askIfNeeded(notifyNewTracks != .off) }
    }
    var weeklyDigest: Bool { didSet { preferences.weeklyDigest = weeklyDigest; askIfNeeded(weeklyDigest) } }

    let preferences: AppPreferences
    let accounts: AccountsService
    private let store: SettingsStore
    private let appleMusicReader: AppleMusicAccountReader

    init(store: SettingsStore, accounts: AccountsService, preferences: AppPreferences = .shared,
         appleMusic: AppleMusicAccountReader) {
        self.store = store
        self.accounts = accounts
        self.preferences = preferences
        self.appleMusicReader = appleMusic
        newSeamRemoval = preferences.newSeamRemovalPolicy
        newSeamMonitoring = preferences.newSeamMonitoring
        threshold = preferences.autoAddThreshold
        explicit = preferences.explicitPreference
        preferOriginal = !preferences.acceptRemasters
        neverLive = !preferences.allowLive
        allowRadioEdits = preferences.allowRadioEdits
        release = preferences.releaseChoice
        recheck = preferences.recheckCadence
        interval = preferences.monitorIntervalMinutes
        wifiOnly = preferences.wifiOnly
        removeInBackground = preferences.removeInBackground
        pauseInLowPower = preferences.pauseInLowPower
        quietHours = preferences.quietHours
        notifyDecide = preferences.notifyDecide
        notifyBreaks = preferences.notifyBreaks
        notifyNewTracks = preferences.notifyNewTracks
        weeklyDigest = preferences.weeklyDigest
    }

    /// What the store holds, without the export or account reads.
    func reloadCounts() async {
        usage = (try? await store.usage()) ?? usage
        confidences = (try? await store.recentConfidences(days: 30)) ?? confidences
    }

    func load() async {
        usage = (try? await store.usage()) ?? .empty
        appleMusic = await appleMusicReader.read()
        confidences = (try? await store.recentConfidences(days: 30)) ?? []
        notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        if let csv = try? await store.historyCSV() {
            let url = URL.temporaryDirectory.appending(path: "Antiphon sync history.csv")
            try? csv.write(to: url, atomically: true, encoding: .utf8)
            exportURL = url
        }
    }

    // MARK: - Presentation

    var header: String { SettingsCopy.header(seams: usage.seams, tracksInSync: usage.tracksInSync) }
    var name: String { accounts.spotifyDisplayName ?? "Antiphon" }
    var spotifyStatus: String { accounts.isSpotifyConnected ? (accounts.spotifyDisplayName ?? "Connected") : "Not connected" }
    var monitoringValue: String { RulesCopy.intervalLabel(interval) }
    var wouldAsk: String { MatchingCopy.wouldAsk(confidences, threshold: threshold) }

    var notificationsValue: String {
        if notificationStatus == .denied { return "Off in iOS" }
        let on = [notifyDecide, notifyBreaks, notifyNewTracks != .off, weeklyDigest].filter { $0 }.count
        return on == 0 ? "Off" : "\(on) of 4"
    }

    var quietHoursOn: Bool {
        get { quietHours != nil }
        set { quietHours = newValue ? (quietHours ?? .init(startMinute: 23 * 60, endMinute: 7 * 60)) : nil }
    }

    // MARK: - Actions

    /// Asks for notification permission the first time one is turned on.
    private func askIfNeeded(_ turnedOn: Bool) {
        guard turnedOn, notificationStatus == .notDetermined else { return }
        Task {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    func resetAll() async throws {
        try await store.resetAll()
        preferences.spotifySignedInAt = nil
        await load()
    }
}
