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
        case .onboarding(let step):
            OnboardingView(model: Self.onboardingModel(step)) {}
        case .shell(let option):
            AppShell(model: Self.shellModel(option))
                .tint(.thread)
                .onAppear {
                    if option == "syncing" || option == "syncing-several" {
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
                    if option == "checking" {
                        // Opening the app: one seam still being read, one read with changes waiting.
                        SeamChecks.shared.begin([PreviewFixtures.lateNightDrive.id, PreviewFixtures.gardenSundays.id])
                        SeamChecks.shared.finish(PreviewFixtures.gardenSundays.id, look: .init(waiting: 3, at: Date()))
                    }
                }
        }
    }

    @MainActor
    private static func onboardingModel(_ step: String?) -> OnboardingModel {
        let model = OnboardingModel(library: PreviewLibraryService(), seams: PreviewSeamRepository(seams: []),
                                    appleMusic: PreviewAppleMusicAccountReader(), requestAppleMusic: {})
        switch step {
        case "connect": model.step = .connect
        case "defaults": model.step = .defaults
        case "twins": model.step = .twins
        default: break
        }
        return model
    }

    @MainActor
    private static func shellModel(_ option: String?) -> AppShellModel {
        let repository = PreviewSeamRepository()
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
            model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id),
                               .match(seamId: PreviewFixtures.lateNightDrive.id, rowId: PreviewFixtures.reviewItems[0].id)]
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
        case "syncing-several": model.showsRunningSyncs = true
        case "preview", "syncing", "synced":
            model.syncFlowSeamId = PreviewFixtures.lateNightDrive.id
            DebugRoute.flowPhase = option
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
        case "syncing":
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
        default:
            await loadOverlap()
            direction = .bidirectional
            return [.twin, .compare, .rules]
        }
    }
}
#endif
