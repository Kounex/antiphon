#if DEBUG
import SwiftUI

/// Opens a screen directly from launch arguments, for screenshots:
///     -AntiphonScreen catalog
///     -AntiphonScreen catalog/SeamLine
/// Unknown values fall back to the normal root.
enum DebugRoute {
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
        let model = AppShellModel(seams: PreviewSeamRepository(), accounts: PreviewAccounts())
        switch option {
        case "library": model.selectedTab = .library
        case "activity": model.selectedTab = .activity
        case "search": model.selectedTab = .search
        case "detail": model.syncsInitialPath = [.seam(PreviewFixtures.lateNightDrive.id)]
        case "rules": model.syncsInitialPath = [.seam(PreviewFixtures.lateNightDrive.id), .rules(PreviewFixtures.lateNightDrive.id)]
        default: break
        }
        return model
    }
}
#endif
