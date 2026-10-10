import AntiphonDesign
import SwiftUI
import SwiftData
import BackgroundTasks

@main
struct AntiphonApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let spotifyAuth: SpotifyAuthManager
    let syncCoordinator: SyncCoordinator
    let shellModel: AppShellModel

    /// Unit tests launch the app as their host; keep it away from the real
    /// store and background scheduler while they run.
    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// A DEBUG screen opened for screenshots: no permission prompts or
    /// background scheduling.
    #if DEBUG
    private static let isDebugRoute = DebugRoute.current != nil
    #else
    private static let isDebugRoute = false
    #endif

    init() {
        if Self.isHostingTests, let inMemory = try? SharedModelContainer.make(inMemory: true) {
            modelContainer = inMemory
        } else {
            modelContainer = SharedModelContainer.container
        }

        // Initialize auth managers
        spotifyAuth = SpotifyAuthManager()
        syncCoordinator = SyncCoordinator(modelContainer: modelContainer)
        let repository = SwiftDataSeamRepository(modelContainer: modelContainer)
        shellModel = AppShellModel(
            seams: repository,
            accounts: spotifyAuth,
            sync: LiveSyncService(modelContainer: modelContainer),
            library: LiveLibraryService(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager()),
            reviews: repository,
            problems: repository,
            catalogSearch: LiveCatalogSearchService(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        )

        // Register background tasks (handler creates its own auth instances)
        if !Self.isHostingTests {
            BackgroundTaskManager.registerTasks(modelContainer: modelContainer)
        }
    }

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let route = DebugRoute.current {
                DebugRouteView(route: route)
                    .environment(spotifyAuth)
                    .environment(syncCoordinator)
                    .modelContainer(modelContainer)
            } else {
                rootView
            }
            #else
            rootView
            #endif
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard !Self.isHostingTests, !Self.isDebugRoute else { return }
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
        AppShell(model: shellModel)
        .environment(spotifyAuth)
        .environment(syncCoordinator)
        .tint(.thread)
    }
}
