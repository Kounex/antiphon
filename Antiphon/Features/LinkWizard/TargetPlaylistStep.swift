import SwiftUI
import MusicKit

/// Step 3: Choose or create the target playlist on the other platform.
///
/// The user can either:
/// - Select an existing playlist to link with, or
/// - Create a new playlist on the target platform (auto-populated with source name)
struct TargetPlaylistStep: View {
    @Bindable var viewModel: LinkWizardViewModel

    private let appleMusicManager = AppleMusicManager()

    var body: some View {
        VStack(spacing: 0) {
            // Header summary
            sourceSummaryBanner
                .padding(.horizontal)
                .padding(.top, 12)

            // Toggle: Existing vs New
            Picker("Target", selection: $viewModel.createNewTarget) {
                Text("Existing Playlist").tag(false)
                Text("Create New").tag(true)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.top, 12)

            // Content
            if viewModel.createNewTarget {
                createNewView
            } else if viewModel.isLoadingTarget {
                loadingView
            } else {
                VStack(spacing: 0) {
                    searchBar
                        .padding(.horizontal)
                        .padding(.top, 12)
                    existingPlaylistList
                }
            }

            // Bottom bar
            bottomBar
        }
        .task {
            await loadTargetPlaylists()
        }
    }

    // MARK: - Source Summary Banner

    private var sourceSummaryBanner: some View {
        HStack(spacing: 12) {
            PlatformBadge(platform: viewModel.sourcePlatform, size: .small)

            VStack(alignment: .leading, spacing: 2) {
                Text("Syncing from")
                    .font(.appCaption)
                    .foregroundStyle(Color.textTertiary)
                Text(viewModel.sourcePlaylistName)
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
            }

            Spacer()

            Image(systemName: "arrow.right")
                .font(.appBody)
                .foregroundStyle(Color.textTertiary)

            PlatformBadge(platform: viewModel.targetPlatform, size: .small)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.surfaceElevated)
        )
    }

    // MARK: - Create New

    private var createNewView: some View {
        VStack(spacing: 24) {
            Spacer()

            // Icon
            ZStack {
                Circle()
                    .fill(viewModel.targetPlatform.color.opacity(0.12))
                    .frame(width: 80, height: 80)

                Image(systemName: "plus.rectangle.on.folder.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(viewModel.targetPlatform.color)
            }

            VStack(spacing: 8) {
                Text("Create a new playlist on")
                    .font(.appBody)
                    .foregroundStyle(Color.textSecondary)

                Text(viewModel.targetPlatform.rawValue)
                    .font(.appTitle2)
                    .foregroundStyle(Color.textPrimary)
            }

            // Name field
            VStack(alignment: .leading, spacing: 8) {
                Text("Playlist name")
                    .font(.appCaptionBold)
                    .foregroundStyle(Color.textSecondary)

                TextField(viewModel.sourcePlaylistName, text: $viewModel.newTargetName)
                    .font(.appBody)
                    .foregroundStyle(Color.textPrimary)
                    .padding(14)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.surfaceElevated)
                            .overlay(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.subtleBorder, lineWidth: 1)
                            )
                    )
            }
            .padding(.horizontal)

            Text("Leave blank to use the same name as the source.")
                .font(.appCaption)
                .foregroundStyle(Color.textTertiary)

            Spacer()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)
                .font(.appBody)

            TextField("Search playlists…", text: $viewModel.targetPlaylistSearchQuery)
                .font(.appBody)
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()

            if !viewModel.targetPlaylistSearchQuery.isEmpty {
                Button {
                    viewModel.targetPlaylistSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.surfaceElevated)
        )
    }

    // MARK: - Existing Playlist List

    @ViewBuilder
    private var existingPlaylistList: some View {
        if viewModel.targetPlatform == .appleMusic {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredTargetAppleMusicPlaylists) { playlist in
                        AppleMusicPlaylistRow(
                            playlist: playlist,
                            isSelected: viewModel.selectedTargetAppleMusicPlaylist?.id == playlist.id
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.selectedTargetAppleMusicPlaylist = playlist
                            }
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(viewModel.filteredTargetSpotifyPlaylists) { playlist in
                        SpotifyPlaylistRow(
                            playlist: playlist,
                            isSelected: viewModel.selectedTargetSpotifyPlaylist?.id == playlist.id
                        ) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                viewModel.selectedTargetSpotifyPlaylist = playlist
                            }
                        }
                    }
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(Color.textSecondary)
            Text("Loading \(viewModel.targetPlatform.rawValue) playlists…")
                .font(.appBody)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.targetPlaylistSearchQuery = ""
                viewModel.goBack()
            } label: {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Back")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)

            Button {
                viewModel.targetPlaylistSearchQuery = ""
                viewModel.advance()
            } label: {
                HStack {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.antiphon)
            .disabled(!viewModel.canAdvanceFromTarget)
            .opacity(viewModel.canAdvanceFromTarget ? 1 : 0.5)
        }
        .padding()
    }

    // MARK: - Data Loading

    private func loadTargetPlaylists() async {
        guard !viewModel.isLoadingTarget else { return }

        viewModel.isLoadingTarget = true
        defer { viewModel.isLoadingTarget = false }

        do {
            if viewModel.targetPlatform == .spotify {
                if viewModel.targetSpotifyPlaylists.isEmpty {
                    let client = SpotifyAPIClient()
                    viewModel.targetSpotifyPlaylists = try await client.getAllPlaylists()
                }
            } else {
                if viewModel.targetAppleMusicPlaylists.isEmpty {
                    await appleMusicManager.requestAuthorization()
                    viewModel.targetAppleMusicPlaylists = try await appleMusicManager.fetchUserPlaylists()
                }
            }
        } catch {
            viewModel.setError("Failed to load target playlists: \(error.localizedDescription)")
        }
    }
}
