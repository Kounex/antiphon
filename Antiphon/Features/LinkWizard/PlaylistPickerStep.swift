import SwiftUI
import MusicKit

/// Step 2: Browse and select a playlist from the chosen source platform.
struct PlaylistPickerStep: View {
    @Bindable var viewModel: LinkWizardViewModel

    private let appleMusicManager = AppleMusicManager()

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            searchBar
                .padding(.horizontal)
                .padding(.top, 12)

            // Content — full-screen spinner only for the initial load; pull-to-refresh
            // keeps the list visible while it reloads
            if viewModel.isLoadingPlaylists && viewModel.spotifyPlaylists.isEmpty && viewModel.appleMusicPlaylists.isEmpty {
                loadingView
            } else if viewModel.sourcePlatform == .spotify {
                spotifyPlaylistList
            } else {
                appleMusicPlaylistList
            }
        }
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .task {
            await loadPlaylistsIfNeeded()
        }
        .refreshable {
            await loadPlaylists()
        }
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)
                .font(.appBody)

            TextField("Search playlists…", text: $viewModel.playlistSearchQuery)
                .font(.appBody)
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()

            if !viewModel.playlistSearchQuery.isEmpty {
                Button {
                    viewModel.playlistSearchQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textTertiary)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.surfaceElevated)
        )
    }

    // MARK: - Spotify Playlist List

    private var spotifyPlaylistList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredSpotifyPlaylists) { playlist in
                    SpotifyPlaylistRow(
                        playlist: playlist,
                        isSelected: viewModel.selectedSpotifyPlaylist?.id == playlist.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.selectedSpotifyPlaylist = playlist
                        }
                    }
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Apple Music Playlist List

    private var appleMusicPlaylistList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(viewModel.filteredAppleMusicPlaylists) { playlist in
                    AppleMusicPlaylistRow(
                        playlist: playlist,
                        isSelected: viewModel.selectedAppleMusicPlaylist?.id == playlist.id
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.selectedAppleMusicPlaylist = playlist
                        }
                    }
                }
            }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 16) {
            Spacer()
            ProgressView()
                .tint(Color.textSecondary)
            Text("Loading playlists…")
                .font(.appBody)
                .foregroundStyle(Color.textSecondary)
            Spacer()
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
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
                viewModel.playlistSearchQuery = ""
                viewModel.advance()
            } label: {
                HStack {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.antiphon)
            .disabled(!viewModel.canAdvanceFromPlaylist)
            .opacity(viewModel.canAdvanceFromPlaylist ? 1 : 0.5)
        }
        .padding()
    }

    // MARK: - Data Loading

    private func loadPlaylistsIfNeeded() async {
        let alreadyLoaded: Bool
        if viewModel.sourcePlatform == .spotify {
            alreadyLoaded = !viewModel.spotifyPlaylists.isEmpty
        } else {
            alreadyLoaded = !viewModel.appleMusicPlaylists.isEmpty
        }
        guard !alreadyLoaded else { return }
        await loadPlaylists()
    }

    private func loadPlaylists() async {
        viewModel.isLoadingPlaylists = true
        defer { viewModel.isLoadingPlaylists = false }

        do {
            if viewModel.sourcePlatform == .spotify {
                let client = SpotifyAPIClient()
                viewModel.spotifyPlaylists = try await client.getAllPlaylists()
            } else {
                await appleMusicManager.requestAuthorization()
                viewModel.appleMusicPlaylists = try await appleMusicManager.fetchUserPlaylists()
            }
        } catch {
            viewModel.setError("Failed to load playlists: \(error.localizedDescription)")
        }
    }
}

// MARK: - Spotify Playlist Row

struct SpotifyPlaylistRow: View {
    let playlist: SpotifyPlaylist
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Artwork
                TrackArtworkView(
                    url: playlist.images?.first?.url,
                    size: 52,
                    cornerRadius: 10
                )

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.appBodyBold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text("\(playlist.tracks.total) tracks")
                            .font(.appCaption)
                            .foregroundStyle(Color.textSecondary)

                        if let owner = playlist.owner.displayName {
                            Text("•")
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                            Text(owner)
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                                .lineLimit(1)
                        }
                    }
                }

                Spacer()

                // Selection check
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.spotifyGreen)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.spotifyGreen.opacity(0.08) : Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                isSelected ? Color.spotifyGreen.opacity(0.3) : Color.subtleBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Apple Music Playlist Row

struct AppleMusicPlaylistRow: View {
    let playlist: Playlist
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                // Artwork placeholder
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.appleMusicPink.opacity(0.15))
                        .frame(width: 52, height: 52)

                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .foregroundStyle(Color.appleMusicPink)
                }

                // Info
                VStack(alignment: .leading, spacing: 3) {
                    Text(playlist.name)
                        .font(.appBodyBold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    Text("Apple Music")
                        .font(.appCaption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                // Selection check
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Color.appleMusicPink)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(isSelected ? Color.appleMusicPink.opacity(0.08) : Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(
                                isSelected ? Color.appleMusicPink.opacity(0.3) : Color.subtleBorder,
                                lineWidth: 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}
