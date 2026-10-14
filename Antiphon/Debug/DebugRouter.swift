#if DEBUG
import SwiftUI

/// Opens a screen directly from launch arguments, for screenshots:
///     -AntiphonScreen catalog
///     -AntiphonScreen catalog/SeamLine
/// Unknown values fall back to the normal root.
enum DebugRoute {
    /// The Settings page to push: `shell/settings/<page>`.
    @MainActor static var settingsPage: String?
    /// Which sync-flow phase to show for `shell/preview|syncing|synced`.
    @MainActor static var flowPhase: String?
    /// Opens scrolled to the bottom, to check the toolbar over content.
    @MainActor static var startScrolled = false
    /// Which new-seam step to open for `newseam/<step>`.
    @MainActor static var newSeamStep: String?

    case catalog(ComponentCatalogView.Page?)
    /// The tab shell on preview data; `shell/library`, `shell/activity`,
    /// `shell/search` pick a tab, `shell/syncing` adds a running sync.
    case shell(String?)
    /// End-to-end checks on the real accounts: `selftest` or `selftest/<scenario>`
    /// (see `SelfTestRunner.run` and `scripts/selftest.sh`).
    case selfTest(String?)
    /// First launch: `onboarding/connect`, `/defaults`, `/twins`.
    case onboarding(String?)

    /// Every route starts on the System theme, so the simulator's appearance
    /// decides it. `shell/settings-flip-…` stores a theme, which would
    /// otherwise stick to every later screenshot.
    static func resetLaunchState(_ defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: AppAppearance.storageKey)
    }

    static var current: DebugRoute? {
        guard let value = UserDefaults.standard.string(forKey: "AntiphonScreen") else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        switch parts.first {
        case "catalog":
            return .catalog(parts.count > 1 ? ComponentCatalogView.Page(rawValue: parts[1]) : nil)
        case "shell":
            return .shell(parts.count > 1 ? parts[1] : nil)
        case "selftest":
            return .selfTest(parts.count > 1 ? parts[1] : nil)
        case "onboarding":
            return .onboarding(parts.count > 1 ? parts[1] : nil)
        case "newseam":
            return .shell("newseam/" + (parts.count > 1 ? parts[1] : "pick"))
        default:
            return nil
        }
    }
}

struct DebugRouteView: View {
    let route: DebugRoute
    @Environment(SyncCoordinator.self) private var syncCoordinator

    var body: some View {
        switch route {
        case .catalog(let page):
            ComponentCatalogView(initialPage: page)
        case .selfTest(let scenario):
            SelfTestView(runner: SelfTestRunner(scenario: scenario))
        case .onboarding(let step) where step == "connect-spotify":
            // Spotify signed in, Apple Music not asked yet (App Store screenshot 02).
            OnboardingView(model: Self.onboardingModel(step)) {}
                .environment(Self.signedInSpotify)
        case .onboarding(let step):
            OnboardingView(model: Self.onboardingModel(step)) {}
        case .shell(let option):
            AppShell(model: Self.shellModel(option))
                .tint(.thread)
                .onAppear {
                    if option == "syncing" || option == "syncing-several" || option == "store" || option == "store-live" {
                        syncCoordinator.simulateRunning(
                            pairId: PreviewFixtures.runClub.id,
                            progress: SyncProgress(totalTracks: 52, completedTracks: 31, failedTracks: 0)
                        )
                    }
                    if option == "syncing-several" {
                        syncCoordinator.simulateRunning(
                            pairId: PreviewFixtures.lateNightDrive.id,
                            progress: SyncProgress(totalTracks: 25, completedTracks: 9, failedTracks: 0,
                                                   phase: .adding(platformName: "Apple Music"))
                        )
                    }
                    if option == "store-live" { Self.runStoreSync(syncCoordinator) }
                    if option == "checking" {
                        // Opening the app: one seam still being read, one read with changes waiting.
                        SeamChecks.shared.begin([PreviewFixtures.lateNightDrive.id, PreviewFixtures.gardenSundays.id])
                        SeamChecks.shared.finish(PreviewFixtures.gardenSundays.id, look: .init(waiting: 3, at: Date()))
                    }
                }
        }
    }

    /// `shell/store-live` (the App Store header and search videos): the store
    /// home with Run Club's sync running, one track every 0.6 s after a 1 s
    /// pause, so the accessory and "tracks in sync" count up from the
    /// screenshot's 31 of 52 to done.
    @MainActor
    private static func runStoreSync(_ coordinator: SyncCoordinator) {
        guard let repository = storeRepository else { return }
        let id = PreviewFixtures.runClub.id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            for done in 32...52 {
                try? await Task.sleep(for: .milliseconds(600))
                coordinator.simulateRunning(pairId: id, progress: SyncProgress(totalTracks: 52, completedTracks: done, failedTracks: 0))
                await repository.setSynced(done, seamId: id)
                StoreChanges.shared.noteChange()
            }
        }
    }

    @MainActor private static var storeRepository: PreviewSeamRepository?

    @MainActor
    private static let signedInSpotify: SpotifyAuthManager = {
        let auth = SpotifyAuthManager()
        auth.isAuthenticated = true
        auth.userProfile = SpotifyUserProfile(id: "preview", displayName: "Maya Klein", email: nil, images: nil, product: "premium")
        return auth
    }()

    @MainActor
    private static func onboardingModel(_ step: String?) -> OnboardingModel {
        var appleMusic = PreviewAppleMusicAccountReader()
        if step == "connect-spotify" { appleMusic.account = AppleMusicAccount(access: .notAsked) }
        let model = OnboardingModel(library: PreviewLibraryService(), seams: PreviewSeamRepository(seams: []),
                                    appleMusic: appleMusic, requestAppleMusic: {})
        switch step {
        case "connect", "connect-spotify": model.step = .connect
        case "defaults": model.step = .defaults
        case "twins": model.step = .twins
        default: break
        }
        return model
    }

    @MainActor
    private static func shellModel(_ option: String?) -> AppShellModel {
        // `store` (or `-AntiphonStoreData YES` with any shell route): the App Store
        // screenshots' data, seven seams and nothing broken.
        let storeData = option == "store" || option == "store-live" || UserDefaults.standard.bool(forKey: "AntiphonStoreData")
        let repository = storeData
            ? PreviewSeamRepository(seams: PreviewFixtures.storeSeams, showsProblems: false)
            : PreviewSeamRepository()
        storeRepository = repository
        let accounts = PreviewAccounts()
        accounts.isSpotifyConnected = option != "problems"
        let model = AppShellModel(seams: repository, accounts: accounts,
                                  sync: PreviewSyncService(), library: PreviewLibraryService(),
                                  reviews: repository, problems: repository, catalogSearch: PreviewCatalogSearchService(),
                                  index: repository, availability: PreviewAvailabilityService(),
                                  activity: repository, settings: repository,
                                  appleMusicAccount: PreviewAppleMusicAccountReader())
        switch option {
        case "library": model.selectedTab = .library
        case "library-playlist":
            model.selectedTab = .library
            model.libraryPath = [.playlist(PreviewLibraryService.spotify[2])]
        case "library-stitch":
            model.selectedTab = .library
            model.startSeam(from: PreviewLibraryService.spotify[2])
        case "library-apple":
            model.selectedTab = .library
            model.libraryPath = [.playlist(PreviewLibraryService.appleMusic[2])]
        case let query? where query.hasPrefix("search-"):
            model.selectedTab = .search
            model.searchModel.query = String(query.dropFirst("search-".count))
        case "activity": model.selectedTab = .activity
        case "activity-new":
            model.selectedTab = .activity
            model.activityModel.tab = .newTracks
        case "activity-run":
            model.selectedTab = .activity
            model.activityPath = [.run(PreviewFixtures.runs[0].id)]
        case "search": model.selectedTab = .search
        case "detail": model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id)]
        case "detail-scrolled":
            model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id)]
            DebugRoute.startScrolled = true
        case "rules": model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id), .rules(PreviewFixtures.lateNightDrive.id)]
        case "review": model.reviewTarget = .init(seamId: nil)
        case "review-removal": model.reviewTarget = .init(seamId: PreviewFixtures.gardenSundays.id)
        case "match":
            // A close match from the seam's track list: nothing in the playlist yet.
            let item = PreviewFixtures.reviewItems[0]
            model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id)]
            model.picking = PickTarget(seam: PreviewFixtures.lateNightDrive, source: item.source, current: .notThere,
                                       candidates: item.candidates)
        case "pick", "pick-yours":
            // Midnight City synced as Antiphon's remaster, or already the person's pick.
            let item = PreviewFixtures.reviewItems[0]
            let current = item.candidates[0].track
            model.picking = PickTarget(seam: PreviewFixtures.lateNightDrive, source: item.source,
                                       current: option == "pick" ? .antiphonsPick(current) : .yourPick(current),
                                       candidates: item.candidates)
        case "conflict":
            model.openConflict = .init(item: PreviewFixtures.conflicts[0], others: [PreviewFixtures.conflicts[1]])
        case "problems": model.syncsPath = [.problems]
        case "settings": model.showsSettings = true
        case let flip? where flip.hasPrefix("settings-flip-"):
            // Opens Settings in one theme and switches with the sheet open.
            let parts = flip.dropFirst("settings-flip-".count).split(separator: "-").map(String.init)
            AppPreferences.shared.appearance = AppAppearance(rawValue: parts.first ?? "light") ?? .light
            model.showsSettings = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                AppPreferences.shared.appearance = AppAppearance(rawValue: parts.last ?? "dark") ?? .dark
            }
        case let page? where page.hasPrefix("settings/"):
            model.showsSettings = true
            DebugRoute.settingsPage = String(page.dropFirst("settings/".count))
        case let step? where step.hasPrefix("newseam/"):
            model.showsNewSeam = true
            DebugRoute.newSeamStep = String(step.dropFirst("newseam/".count))
        case "seam-swap":
            // One seam's screen, then the path replaced by another (as Review,
            // a widget or Library do): the second seam must show, not the first.
            model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id)]
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                model.syncsPath = [.seam(PreviewFixtures.runClub.id)]
            }
        case "syncing-several":
            model.reopenRunningSyncs(ids: [PreviewFixtures.runClub.id, PreviewFixtures.lateNightDrive.id], focus: nil)
        case "preview", "syncing", "synced", "syncing-hide":
            model.openSyncFlow(seamId: PreviewFixtures.lateNightDrive.id)
            DebugRoute.flowPhase = option
            if option == "syncing-hide" {
                // The live sheet presses Hide after 2 s; then the accessory reopens it.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(5))
                    model.reopenRunningSyncs(ids: [PreviewFixtures.lateNightDrive.id], focus: PreviewFixtures.lateNightDrive.id)
                }
            }
        default: break
        }
        return model
    }
}
#endif

#if DEBUG
extension SyncFlowModel {
    /// Puts the flow in a phase for screenshots, without touching a platform.
    func debugApplyRoute(coordinator: SyncCoordinator) async {
        guard let phase = DebugRoute.flowPhase else { return }
        await load()
        switch phase {
        case "syncing", "syncing-hide":
            debugStart()
            coordinator.simulateRunning(pairId: seamId, progress: SyncProgress(totalTracks: 35, completedTracks: 20, failedTracks: 0))
        case "synced":
            debugFinish(SyncResult(pairId: seamId, status: .success, tracksAdded: 35))
        default:
            break
        }
    }
}

extension NewSeamModel {
    /// Walks the flow to a step with the preview library, for screenshots.
    func debugPrepare() async -> [NewSeamStep] {
        guard let step = DebugRoute.newSeamStep, step != "pick" else { return [] }
        await loadPlaylists()
        if let workout = visiblePlaylists.first(where: { $0.name == "Workout Mix 2026" }) { toggle(workout) }
        startQueue()
        await loadTwins()
        switch step {
        case "twin": return [.twin]
        case "compare":
            await loadOverlap()
            return [.twin, .compare]
        case "sync":
            // "Preview changes" on the last step: the seam's first preview, inside the wizard.
            await loadOverlap()
            let id = (try? await createSeam()) ?? PreviewFixtures.lateNightDrive.id
            return [.twin, .compare, .rules, .sync(id)]
        default:
            await loadOverlap()
            direction = .bidirectional
            return [.twin, .compare, .rules]
        }
    }
}
#endif
