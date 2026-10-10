#if DEBUG
import SwiftUI

/// Opens a screen directly from launch arguments, for screenshots:
///     -AntiphonScreen catalog
///     -AntiphonScreen catalog/SeamLine
/// Unknown values fall back to the normal root.
enum DebugRoute {
    /// Which sync-flow phase to show for `shell/preview|syncing|synced`.
    @MainActor static var flowPhase: String?
    /// Which new-seam step to open for `newseam/<step>`.
    @MainActor static var newSeamStep: String?

    case catalog(ComponentCatalogView.Page?)
    /// The tab shell on preview data; `shell/library`, `shell/activity`,
    /// `shell/search` pick a tab, `shell/syncing` adds a running sync.
    case shell(String?)

    static var current: DebugRoute? {
        guard let value = UserDefaults.standard.string(forKey: "AntiphonScreen") else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        switch parts.first {
        case "catalog":
            return .catalog(parts.count > 1 ? ComponentCatalogView.Page(rawValue: parts[1]) : nil)
        case "shell":
            return .shell(parts.count > 1 ? parts[1] : nil)
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
        case .shell(let option):
            AppShell(model: Self.shellModel(option))
                .tint(.thread)
                .onAppear {
                    if option == "syncing" {
                        syncCoordinator.simulateRunning(
                            pairId: PreviewFixtures.runClub.id,
                            progress: SyncProgress(totalTracks: 52, completedTracks: 31, failedTracks: 0)
                        )
                    }
                }
        }
    }

    @MainActor
    private static func shellModel(_ option: String?) -> AppShellModel {
        let model = AppShellModel(seams: PreviewSeamRepository(), accounts: PreviewAccounts(),
                                  sync: PreviewSyncService(), library: PreviewLibraryService())
        switch option {
        case "library": model.selectedTab = .library
        case "activity": model.selectedTab = .activity
        case "search": model.selectedTab = .search
        case "detail": model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id)]
        case "rules": model.syncsPath = [.seam(PreviewFixtures.lateNightDrive.id), .rules(PreviewFixtures.lateNightDrive.id)]
        case let step? where step.hasPrefix("newseam/"):
            model.showsNewSeam = true
            DebugRoute.newSeamStep = String(step.dropFirst("newseam/".count))
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
