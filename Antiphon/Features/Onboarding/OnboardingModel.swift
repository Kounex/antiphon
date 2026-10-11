import Foundation
import Observation
import UserNotifications

/// Welcome → connect both sides → pick defaults → link twins found.
/// Nothing syncs until the person reviews a seam's first sync.
@MainActor
@Observable
final class OnboardingModel {
    enum Step: Int, CaseIterable { case welcome, connect, defaults, twins }

    var step: Step = .welcome

    // Connect
    private(set) var spotifyPlaylists: [LibraryPlaylist]?
    private(set) var applePlaylists: [LibraryPlaylist]?
    private(set) var appleMusic = AppleMusicAccount(access: .notAsked)

    // Defaults
    var removal: RemovalPolicy
    var keepWatching: Bool
    var notifyDecide: Bool
    var threshold: Int

    // Twins
    private(set) var suggestions: [TwinSuggester.Suggestion] = []
    var checked: Set<String> = []
    private(set) var isScanning = false
    private(set) var restLine: String?
    private(set) var isLinking = false
    private(set) var linkError: String?

    private let library: LibraryService
    private let seams: SeamRepository
    private let preferences: AppPreferences
    private let appleMusicReader: AppleMusicAccountReader
    private let requestAppleMusic: @Sendable () async -> Void

    init(library: LibraryService, seams: SeamRepository, preferences: AppPreferences = .shared,
         appleMusic: AppleMusicAccountReader, requestAppleMusic: @escaping @Sendable () async -> Void) {
        self.library = library
        self.seams = seams
        self.preferences = preferences
        self.appleMusicReader = appleMusic
        self.requestAppleMusic = requestAppleMusic
        removal = preferences.newSeamRemovalPolicy == .mirror ? .mirror : .keep
        keepWatching = preferences.newSeamMonitoring
        notifyDecide = preferences.notifyDecide
        threshold = preferences.autoAddThreshold
    }

    var stepNumber: String? {
        switch step {
        case .welcome: nil
        case .connect: "Step 1 of 3"
        case .defaults: "Step 2 of 3"
        case .twins: "Step 3 of 3"
        }
    }

    // MARK: - Connect

    func refreshAccounts(spotifyConnected: Bool) async {
        appleMusic = await appleMusicReader.read()
        if spotifyConnected, spotifyPlaylists == nil { spotifyPlaylists = try? await library.playlists(on: .spotify) }
        if appleMusic.access == .allowed, applePlaylists == nil { applePlaylists = try? await library.playlists(on: .appleMusic) }
    }

    func connectAppleMusic(spotifyConnected: Bool) async {
        await requestAppleMusic()
        await refreshAccounts(spotifyConnected: spotifyConnected)
    }

    func spotifySummary(name: String?) -> String {
        [name, spotifyPlaylists.map { PlanCopy.count($0.count, "playlist") }].compactMap { $0 }.joined(separator: " · ")
    }

    var appleSummary: String {
        [appleMusic.storefront, applePlaylists.map { PlanCopy.count($0.count, "playlist") }].compactMap { $0 }.joined(separator: " · ")
    }

    func canContinueFromConnect(spotifyConnected: Bool) -> Bool {
        spotifyConnected && appleMusic.access == .allowed
    }

    // MARK: - Defaults

    /// Saves the choices; asks for notifications only if they're wanted.
    func saveDefaults() async {
        preferences.newSeamRemovalPolicy = removal
        preferences.newSeamMonitoring = keepWatching
        preferences.notifyDecide = notifyDecide
        preferences.autoAddThreshold = threshold
        if notifyDecide {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    // MARK: - Twins

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        defer { isScanning = false }
        let spotify = (try? await library.playlists(on: .spotify)) ?? spotifyPlaylists ?? []
        let apple = (try? await library.playlists(on: .appleMusic)) ?? applePlaylists ?? []
        let existing = (try? await seams.seams()) ?? []
        let linked = Set(existing.flatMap { [$0.spotify.playlistId, $0.appleMusic.playlistId] })
        let pairs = TwinSuggester.candidates(spotify: spotify, appleMusic: apple, linked: linked)

        var found: [TwinSuggester.Suggestion] = []
        for (index, pair) in pairs.enumerated() {
            guard index < TwinSuggester.maxOverlapFetches,
                  let left = try? await library.tracks(of: pair.spotify),
                  let right = try? await library.tracks(of: pair.appleMusic) else {
                found.append(TwinSuggester.suggestion(pair, shared: nil, spotifyCount: 0, appleCount: 0))
                continue
            }
            let shared = Overlap.compute(source: left, target: right).both.count
            found.append(TwinSuggester.suggestion(pair, shared: shared, spotifyCount: left.count, appleCount: right.count))
        }
        suggestions = found
        checked = Set(found.filter(\.isChecked).map(\.id))
        let paired = Set(pairs.flatMap { [$0.spotify.id, $0.appleMusic.id] }).union(linked)
        restLine = TwinSuggester.restLine(
            spotify: spotify.filter { $0.blockedReason == nil && !paired.contains($0.id) }.count,
            appleMusic: apple.filter { $0.isEditable && !paired.contains($0.id) }.count
        )
    }

    var linkTitle: String {
        checked.isEmpty ? "Finish" : "Link \(PlanCopy.count(checked.count, "seam"))"
    }

    func toggle(_ suggestion: TwinSuggester.Suggestion) {
        if checked.contains(suggestion.id) { checked.remove(suggestion.id) } else { checked.insert(suggestion.id) }
    }

    /// Links the checked twins both ways. Returns false if one couldn't be linked.
    func finish() async -> Bool {
        isLinking = true
        defer { isLinking = false }
        for suggestion in suggestions where checked.contains(suggestion.id) {
            do {
                _ = try await seams.create(SeamDraft(
                    source: suggestion.pair.spotify, target: .existing(suggestion.pair.appleMusic), direction: .bidirectional,
                    removalPolicy: TwinSuggester.removalPolicy(for: removal),
                    isMonitored: keepWatching, monitorIntervalMinutes: preferences.monitorIntervalMinutes
                ))
                checked.remove(suggestion.id)
            } catch {
                linkError = "Antiphon couldn't link \(suggestion.title). The others are linked; add it later from Library."
                return false
            }
        }
        preferences.hasCompletedOnboarding = true
        return true
    }

    func skip() {
        preferences.hasCompletedOnboarding = true
    }
}
