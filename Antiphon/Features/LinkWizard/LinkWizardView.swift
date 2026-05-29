import SwiftUI
import SwiftData
import MusicKit

/// The main Link Wizard — a multi-step sheet flow that guides the user through
/// pairing a Spotify playlist with an Apple Music playlist.
///
/// Steps:
/// 1. Choose source platform
/// 2. Pick a playlist from the source
/// 3. Match or create a target playlist on the other side
/// 4. Configure sync direction + confirm
struct LinkWizardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SyncCoordinator.self) private var syncCoordinator

    @State private var viewModel = LinkWizardViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Progress bar
                    stepProgressBar
                        .padding(.horizontal, 20)
                        .padding(.top, 8)

                    // Step content
                    TabView(selection: $viewModel.currentStep) {
                        PlatformPickerStep(viewModel: viewModel)
                            .tag(LinkWizardStep.pickPlatform)

                        PlaylistPickerStep(viewModel: viewModel)
                            .tag(LinkWizardStep.pickPlaylist)

                        TargetPlaylistStep(viewModel: viewModel)
                            .tag(LinkWizardStep.pickTarget)

                        ConfirmLinkStep(viewModel: viewModel)
                            .tag(LinkWizardStep.confirm)
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .animation(.easeInOut(duration: 0.3), value: viewModel.currentStep)
                }
            }
            .navigationTitle(viewModel.currentStep.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .alert("Error", isPresented: $viewModel.showError) {
                Button("OK") {}
            } message: {
                Text(viewModel.errorMessage ?? "An unexpected error occurred.")
            }
            .onChange(of: viewModel.didComplete) { _, completed in
                if completed {
                    // Save the new SyncPair
                    if let pair = viewModel.buildSyncPair() {
                        modelContext.insert(pair)
                        try? modelContext.save()
                        
                        syncCoordinator.startSync(
                            pairId: pair.id,
                            action: .initialSync
                        )
                    }
                    dismiss()
                }
            }
        }
        .presentationBackground(Color.appBackground)
        .interactiveDismissDisabled(viewModel.currentStep != .pickPlatform)
    }

    // MARK: - Progress Bar

    private var stepProgressBar: some View {
        HStack(spacing: 6) {
            ForEach(LinkWizardStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step <= viewModel.currentStep
                        ? AnyShapeStyle(AppGradients.brand)
                        : AnyShapeStyle(Color.surfaceElevated))
                    .frame(height: 4)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.currentStep)
            }
        }
    }
}

// MARK: - Step Enum

enum LinkWizardStep: Int, CaseIterable, Comparable {
    case pickPlatform = 0
    case pickPlaylist = 1
    case pickTarget = 2
    case confirm = 3

    var title: String {
        switch self {
        case .pickPlatform: return "Choose Platform"
        case .pickPlaylist: return "Select Playlist"
        case .pickTarget: return "Target Playlist"
        case .confirm: return "Confirm Link"
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

// MARK: - View Model

@Observable
@MainActor
final class LinkWizardViewModel {
    // Step tracking
    var currentStep: LinkWizardStep = .pickPlatform
    var didComplete = false

    // Step 1: Platform selection
    var sourcePlatform: Platform = .spotify

    // Step 2: Source playlist
    var spotifyPlaylists: [SpotifyPlaylist] = []
    var appleMusicPlaylists: [Playlist] = []
    var selectedSpotifyPlaylist: SpotifyPlaylist?
    var selectedAppleMusicPlaylist: Playlist?
    var isLoadingPlaylists = false
    var playlistSearchQuery = ""

    // Step 3: Target playlist
    var targetSpotifyPlaylists: [SpotifyPlaylist] = []
    var targetAppleMusicPlaylists: [Playlist] = []
    var selectedTargetSpotifyPlaylist: SpotifyPlaylist?
    var selectedTargetAppleMusicPlaylist: Playlist?
    var isLoadingTarget = false
    var createNewTarget = false
    var newTargetName = ""
    var targetPlaylistSearchQuery = ""

    // Step 4: Confirm
    var syncDirection: SyncDirection = .bidirectional
    var autoMonitor = true

    // Error
    var showError = false
    var errorMessage: String?

    // MARK: - Navigation

    private func dismissKeyboard() {
        #if canImport(UIKit)
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    func advance() {
        dismissKeyboard()
        guard let nextStep = LinkWizardStep(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = nextStep
    }

    func goBack() {
        dismissKeyboard()
        guard let prevStep = LinkWizardStep(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prevStep
    }

    // MARK: - Source Playlist Info

    var sourcePlaylistName: String {
        if sourcePlatform == .spotify {
            return selectedSpotifyPlaylist?.name ?? "—"
        } else {
            return selectedAppleMusicPlaylist?.name ?? "—"
        }
    }

    var sourceTrackCount: Int {
        if sourcePlatform == .spotify {
            return selectedSpotifyPlaylist?.tracks.total ?? 0
        } else {
            return 0 // Apple Music doesn't expose count until loaded
        }
    }

    var sourceImageURL: String? {
        if sourcePlatform == .spotify {
            return selectedSpotifyPlaylist?.images?.first?.url
        }
        return nil
    }

    // MARK: - Target Playlist Info

    var targetPlatform: Platform {
        sourcePlatform == .spotify ? .appleMusic : .spotify
    }

    var targetPlaylistName: String {
        if createNewTarget {
            return newTargetName.isEmpty ? sourcePlaylistName : newTargetName
        }
        if targetPlatform == .spotify {
            return selectedTargetSpotifyPlaylist?.name ?? "—"
        } else {
            return selectedTargetAppleMusicPlaylist?.name ?? "—"
        }
    }

    // MARK: - Filtered Playlists

    var filteredSpotifyPlaylists: [SpotifyPlaylist] {
        if playlistSearchQuery.isEmpty { return spotifyPlaylists }
        return spotifyPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(playlistSearchQuery)
        }
    }

    var filteredAppleMusicPlaylists: [Playlist] {
        if playlistSearchQuery.isEmpty { return appleMusicPlaylists }
        return appleMusicPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(playlistSearchQuery)
        }
    }

    var filteredTargetSpotifyPlaylists: [SpotifyPlaylist] {
        if targetPlaylistSearchQuery.isEmpty { return targetSpotifyPlaylists }
        return targetSpotifyPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(targetPlaylistSearchQuery)
        }
    }

    var filteredTargetAppleMusicPlaylists: [Playlist] {
        if targetPlaylistSearchQuery.isEmpty { return targetAppleMusicPlaylists }
        return targetAppleMusicPlaylists.filter {
            $0.name.localizedCaseInsensitiveContains(targetPlaylistSearchQuery)
        }
    }

    // MARK: - Validation

    var canAdvanceFromPlaylist: Bool {
        if sourcePlatform == .spotify {
            return selectedSpotifyPlaylist != nil
        } else {
            return selectedAppleMusicPlaylist != nil
        }
    }

    var canAdvanceFromTarget: Bool {
        if createNewTarget {
            return true // We'll create with the source name
        }
        if targetPlatform == .spotify {
            return selectedTargetSpotifyPlaylist != nil
        } else {
            return selectedTargetAppleMusicPlaylist != nil
        }
    }

    // MARK: - Build SyncPair

    func buildSyncPair() -> SyncPair? {
        let spotifyId: String
        let spotifyName: String
        let spotifySnapshot: String?
        let spotifyImage: String?
        let amId: String
        let amName: String

        if sourcePlatform == .spotify {
            guard let sp = selectedSpotifyPlaylist else { return nil }
            spotifyId = sp.id
            spotifyName = sp.name
            spotifySnapshot = sp.snapshotId
            spotifyImage = sp.images?.first?.url

            if createNewTarget {
                // Will be created during first sync
                amId = "pending-creation-\(UUID().uuidString)"
                amName = newTargetName.isEmpty ? sp.name : newTargetName
            } else {
                guard let am = selectedTargetAppleMusicPlaylist else { return nil }
                amId = am.id.rawValue
                amName = am.name
            }
        } else {
            guard let am = selectedAppleMusicPlaylist else { return nil }
            amId = am.id.rawValue
            amName = am.name

            if createNewTarget {
                spotifyId = "pending-creation-\(UUID().uuidString)"
                spotifyName = newTargetName.isEmpty ? am.name : newTargetName
                spotifySnapshot = nil
                spotifyImage = nil
            } else {
                guard let sp = selectedTargetSpotifyPlaylist else { return nil }
                spotifyId = sp.id
                spotifyName = sp.name
                spotifySnapshot = sp.snapshotId
                spotifyImage = sp.images?.first?.url
            }
        }

        let pair = SyncPair(
            spotifyPlaylistId: spotifyId,
            spotifyPlaylistName: spotifyName,
            appleMusicPlaylistId: amId,
            appleMusicPlaylistName: amName,
            syncDirection: syncDirection
        )
        pair.spotifySnapshotId = spotifySnapshot
        pair.spotifyImageURL = spotifyImage
        pair.isMonitored = autoMonitor

        return pair
    }

    // MARK: - Error Helper

    func setError(_ message: String) {
        errorMessage = message
        showError = true
    }
}
