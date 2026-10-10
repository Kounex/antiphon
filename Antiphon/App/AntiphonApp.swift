import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct AntiphonApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let spotifyAuth: SpotifyAuthManager
    let syncCoordinator: SyncCoordinator

    /// Unit tests launch the app as their host; keep it away from the real
    /// store and background scheduler while they run.
    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    init() {
        if Self.isHostingTests, let inMemory = try? SharedModelContainer.make(inMemory: true) {
            modelContainer = inMemory
        } else {
            modelContainer = SharedModelContainer.container
        }

        // Initialize auth managers
        spotifyAuth = SpotifyAuthManager()
        syncCoordinator = SyncCoordinator(modelContainer: modelContainer)

        // Register background tasks (handler creates its own auth instances)
        if !Self.isHostingTests {
            BackgroundTaskManager.registerTasks(modelContainer: modelContainer)
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard !Self.isHostingTests else { return }
            switch newPhase {
            case .active:
                NotificationManager.requestPermissionIfNeeded()
                // A background token-refresh failure may have cleared the
                // Keychain — re-sync the observable auth state with reality.
                spotifyAuth.refreshAuthStatus()
            case .background:
                BackgroundTaskManager.scheduleBackgroundRefresh()
            default:
                break
            }
        }
    }

    private var rootView: some View {
        DashboardView()
            .environment(spotifyAuth)
            .environment(syncCoordinator)
            .preferredColorScheme(.dark)
    }
}
