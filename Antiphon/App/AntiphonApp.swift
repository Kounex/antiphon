import AntiphonDesign
import SwiftUI
import SwiftData
import BackgroundTasks
import MusicKit

@main
struct AntiphonApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let spotifyAuth: SpotifyAuthManager
    let syncCoordinator: SyncCoordinator
    let shellModel: AppShellModel
    let onboardingModel: OnboardingModel
    /// First launch shows onboarding; people who already have seams skip it.
    @State private var showsOnboarding: Bool
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

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
        #if DEBUG
        if Self.isDebugRoute { DebugRoute.resetLaunchState() }
        #endif
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
            catalogSearch: LiveCatalogSearchService(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager()),
            index: repository,
            availability: LiveAvailabilityService(),
            activity: repository,
            settings: repository,
            appleMusicAccount: LiveAppleMusicAccountReader()
        )

        onboardingModel = OnboardingModel(
            library: LiveLibraryService(spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager()),
            seams: repository, appleMusic: LiveAppleMusicAccountReader(),
            requestAppleMusic: { _ = await MusicAuthorization.request() }
        )
        let preferences = AppPreferences.shared
        if !preferences.hasCompletedOnboarding,
           (try? ModelContext(modelContainer).fetchCount(FetchDescriptor<SyncPair>())) ?? 0 > 0 {
            preferences.hasCompletedOnboarding = true
        }
        _showsOnboarding = State(initialValue: !preferences.hasCompletedOnboarding && !Self.isHostingTests)

        // Register background tasks (handler creates its own auth instances)
        if !Self.isHostingTests {
            BackgroundTaskManager.registerTasks(modelContainer: modelContainer)
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
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
            .onAppear { AppearanceApplier.apply(appearance) }
            .onChange(of: appearance) { _, appearance in
                AppearanceApplier.apply(appearance)
                guard !Self.isHostingTests, !Self.isDebugRoute else { return }
                AppIconSwitcher.request(appearance)
            }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            guard !Self.isHostingTests, !Self.isDebugRoute else { return }
            switch newPhase {
            case .active:
                // Notification permission is asked for in onboarding, or when
                // a notification is turned on in Settings.
                // A background token-refresh failure may have cleared the
                // Keychain — re-sync the observable auth state with reality.
                spotifyAuth.refreshAuthStatus()
                AppIconSwitcher.request(appearance)
            case .background:
                BackgroundTaskManager.scheduleBackgroundRefresh(modelContainer: modelContainer)
            default:
                break
            }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        Group {
            if showsOnboarding {
                OnboardingView(model: onboardingModel) {
                    withAnimation(.smooth) { showsOnboarding = false }
                    Task { await shellModel.refresh() }
                }
            } else {
                AppShell(model: shellModel)
            }
        }
        .environment(spotifyAuth)
        .environment(syncCoordinator)
        .tint(.thread)
    }
}
