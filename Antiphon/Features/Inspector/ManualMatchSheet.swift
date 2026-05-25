import SwiftUI
import MusicKit

/// A sheet that lets users manually search for a track on the target platform
/// and link it to resolve an unmatched track.
struct ManualMatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(SpotifyAuthManager.self) private var spotifyAuth

    let track: CachedTrack
    let targetPlatform: UnmatchedPlatform

    @State private var searchQuery = ""
    @State private var isSearching = false
    @State private var appleMusicResults: [Song] = []
    @State private var spotifyResults: [SpotifyTrack] = []
    @State private var isLinking = false
    @State private var linkError: String?
    @State private var didLink = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    // Source track info
                    sourceTrackBanner

                    // Search bar
                    searchBar
                        .padding()

                    // Results
                    if isSearching {
                        VStack {
                            Spacer()
                            ProgressView()
                                .tint(Color.textSecondary)
                            Text("Searching…")
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                            Spacer()
                        }
                    } else if didLink {
                        VStack(spacing: 16) {
                            Spacer()
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(Color.syncSuccess)
                            Text("Track Linked!")
                                .font(.appTitle)
                                .foregroundStyle(Color.textPrimary)
                            Text("This track will sync on the next run.")
                                .font(.appBody)
                                .foregroundStyle(Color.textSecondary)
                            Spacer()
                        }
                    } else if !appleMusicResults.isEmpty || !spotifyResults.isEmpty {
                        resultsList
                    } else if !searchQuery.isEmpty {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.textTertiary)
                            Text("No results found")
                                .font(.appBody)
                                .foregroundStyle(Color.textSecondary)
                            Text("Try different search terms or check the spelling.")
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                            Spacer()
                        }
                    } else {
                        VStack(spacing: 12) {
                            Spacer()
                            Image(systemName: targetPlatform == .appleMusic
                                  ? "apple.logo" : "waveform")
                                .font(.system(size: 40))
                                .foregroundStyle(Color.textTertiary)
                            Text("Search \(targetPlatform == .appleMusic ? "Apple Music" : "Spotify")")
                                .font(.appBody)
                                .foregroundStyle(Color.textSecondary)
                            Text("Find the matching song to link it manually.")
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                            Spacer()
                        }
                    }

                    if let error = linkError {
                        Text(error)
                            .font(.appCaption)
                            .foregroundStyle(Color.syncError)
                            .padding()
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Manual Match")
                        .font(.appTitle3)
                        .foregroundStyle(Color.textPrimary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(didLink ? "Done" : "Cancel") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .presentationBackground(Color.appBackground)
        .onAppear {
            // Pre-fill with the track's title + artist
            searchQuery = "\(track.artist) \(track.title)"
            Task { await search() }
        }
    }

    // MARK: - Source Track Banner

    private var sourceTrackBanner: some View {
        HStack(spacing: 12) {
            TrackArtworkView(url: track.artworkURL, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Finding match for:")
                    .font(.appMicro)
                    .foregroundStyle(Color.textTertiary)
                Text(track.title)
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            // Target platform badge
            PlatformBadge(
                platform: targetPlatform == .appleMusic ? .appleMusic : .spotify,
                size: .small
            )
        }
        .padding()
        .background(Color.surfaceElevated)
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(Color.textTertiary)

            TextField("Search \(targetPlatform == .appleMusic ? "Apple Music" : "Spotify")…",
                      text: $searchQuery)
                .font(.appBody)
                .foregroundStyle(Color.textPrimary)
                .autocorrectionDisabled()
                .onSubmit {
                    Task { await search() }
                }

            if !searchQuery.isEmpty {
                Button {
                    searchQuery = ""
                    appleMusicResults = []
                    spotifyResults = []
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Button {
                Task { await search() }
            } label: {
                Text("Search")
                    .font(.appCaptionBold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(AppGradients.brand))
            }
            .disabled(searchQuery.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.surfaceElevated))
    }

    // MARK: - Results List

    private var resultsList: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                if targetPlatform == .appleMusic {
                    ForEach(appleMusicResults, id: \.id) { song in
                        AppleMusicResultRow(song: song) {
                            Task { await linkAppleMusicTrack(song) }
                        }
                    }
                } else {
                    ForEach(spotifyResults, id: \.id) { spotifyTrack in
                        SpotifyResultRow(track: spotifyTrack) {
                            Task { await linkSpotifyTrack(spotifyTrack) }
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }

    // MARK: - Search

    @MainActor
    private func search() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        isSearching = true
        linkError = nil
        defer { isSearching = false }

        do {
            if targetPlatform == .appleMusic {
                let am = AppleMusicManager()
                appleMusicResults = try await am.searchCatalog(query: query, limit: 15)
            } else {
                let client = SpotifyAPIClient(authManager: spotifyAuth)
                spotifyResults = try await client.search(query: query, limit: 15)
            }
        } catch {
            linkError = "Search failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Link Actions

    @MainActor
    private func linkAppleMusicTrack(_ song: Song) async {
        isLinking = true
        linkError = nil
        defer { isLinking = false }

        do {
            // Add to the Apple Music playlist
            if let syncPair = track.syncPair {
                let am = AppleMusicManager()
                let playlists = try await am.fetchUserPlaylists()
                if let playlist = playlists.first(where: { $0.id.rawValue == syncPair.appleMusicPlaylistId }) {
                    try await am.addTrack(song, to: playlist)
                }
            }

            // Update the cached track
            track.appleMusicTrackId = song.id.rawValue
            track.unmatchedPlatform = nil
            if track.source == .spotify {
                track.source = .both
            }
            try? modelContext.save()
            didLink = true
        } catch {
            linkError = "Failed to link: \(error.localizedDescription)"
        }
    }

    @MainActor
    private func linkSpotifyTrack(_ spotifyTrack: SpotifyTrack) async {
        isLinking = true
        linkError = nil
        defer { isLinking = false }

        do {
            // Add to the Spotify playlist
            if let syncPair = track.syncPair {
                let client = SpotifyAPIClient(authManager: spotifyAuth)
                try await client.addTracksToPlaylist(
                    playlistId: syncPair.spotifyPlaylistId,
                    trackUris: [spotifyTrack.uri]
                )
            }

            // Update the cached track
            track.spotifyTrackUri = spotifyTrack.uri
            track.unmatchedPlatform = nil
            if track.source == .appleMusic {
                track.source = .both
            }
            try? modelContext.save()
            didLink = true
        } catch {
            linkError = "Failed to link: \(error.localizedDescription)"
        }
    }
}

// MARK: - Apple Music Result Row

struct AppleMusicResultRow: View {
    let song: Song
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                // Artwork
                if let artwork = song.artwork {
                    ArtworkImage(artwork, width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.surfaceElevated)
                        .frame(width: 44, height: 44)
                        .overlay {
                            Image(systemName: "music.note")
                                .foregroundStyle(Color.textTertiary)
                        }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(.appBody)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    Text(song.artistName)
                        .font(.appCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)

                    if let albumTitle = song.albumTitle {
                        Text(albumTitle)
                            .font(.appMicro)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "link.badge.plus")
                    .font(.appBody)
                    .foregroundStyle(Color.appleMusicPink)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Spotify Result Row

struct SpotifyResultRow: View {
    let track: SpotifyTrack
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                TrackArtworkView(
                    url: track.album?.images?.first?.url,
                    size: 44,
                    cornerRadius: 8
                )

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.name)
                        .font(.appBody)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    Text(track.primaryArtist)
                        .font(.appCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)

                    if let album = track.album?.name {
                        Text(album)
                            .font(.appMicro)
                            .foregroundStyle(Color.textTertiary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                Image(systemName: "link.badge.plus")
                    .font(.appBody)
                    .foregroundStyle(Color.spotifyGreen)
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.cardBackground)
            )
        }
        .buttonStyle(.plain)
    }
}
