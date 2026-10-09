import SwiftUI
import SwiftData
import MusicKit

/// A sheet that lets users manually search for a track on the target platform
/// and link it to resolve an unmatched track.
struct ManualMatchSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    let track: CachedTrack
    let targetPlatform: UnmatchedPlatform
    /// Display copies taken at open: linking can merge into another row and
    /// delete `track` while the sheet still shows its confirmation.
    private let trackTitle: String
    private let trackArtist: String
    private let trackArtworkURL: String?

    @State private var searchQuery: String
    @State private var isSearching = false
    @State private var appleMusicResults: [Song] = []
    @State private var spotifyResults: [SpotifyTrack] = []
    @State private var isLinking = false
    @State private var linkError: String?
    @State private var didLink = false
    @State private var showDismissConfirmation = false

    init(track: CachedTrack, targetPlatform: UnmatchedPlatform) {
        self.track = track
        self.targetPlatform = targetPlatform
        self.trackTitle = track.title
        self.trackArtist = track.artist
        self.trackArtworkURL = track.artworkURL
        // Seed in init, not onAppear — the .task auto-search can run before
        // onAppear and would otherwise fire with an empty query.
        _searchQuery = State(initialValue: "\(track.artist) \(track.title)")
    }

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
                if !didLink {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Dismiss") {
                            showDismissConfirmation = true
                        }
                        .foregroundStyle(Color.syncSuccess)
                    }
                }
            }
            .alert("Dismiss Mismatch?", isPresented: $showDismissConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Dismiss", role: .none) {
                    track.unmatchedPlatform = nil
                    track.syncState = .synced
                    try? modelContext.save()
                    dismiss()
                }
            } message: {
                Text("This will mark the track as synced and ignore the missing match. This action can only be reversed by running a Full Rebuild.")
            }
        }
        .presentationBackground(Color.appBackground)
        .overlay {
            if isLinking {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(.white)
                        Text("Linking track…")
                            .font(.appBody)
                            .foregroundStyle(.white)
                    }
                    .padding(24)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Color.surfaceElevated)
                    )
                }
            }
        }
        .task {
            await search()
        }
        // Flash the confirmation, then close — the row is resolved, so there
        // is nothing left to do in the sheet.
        .task(id: didLink) {
            guard didLink else { return }
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    // MARK: - Source Track Banner

    private var sourceTrackBanner: some View {
        HStack(spacing: 12) {
            TrackArtworkView(url: trackArtworkURL, size: 44, cornerRadius: 8)

            VStack(alignment: .leading, spacing: 2) {
                Text("Finding match for:")
                    .font(.appMicro)
                    .foregroundStyle(Color.textTertiary)
                Text(trackTitle)
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                Text(trackArtist)
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
                        .disabled(isLinking)
                    }
                } else {
                    ForEach(spotifyResults, id: \.id) { spotifyTrack in
                        SpotifyResultRow(track: spotifyTrack) {
                            Task { await linkSpotifyTrack(spotifyTrack) }
                        }
                        .disabled(isLinking)
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
        appleMusicResults = []
        spotifyResults = []
        defer { isSearching = false }

        do {
            if targetPlatform == .appleMusic {
                let am = AppleMusicManager()
                appleMusicResults = try await am.searchCatalog(query: query, limit: 15)
            } else {
                let client = SpotifyAPIClient()
                spotifyResults = try await client.search(query: query, limit: 10)
            }
        } catch {
            linkError = "Search failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Link Actions

    @MainActor
    private func linkAppleMusicTrack(_ song: Song) async {
        guard !isLinking else { return }
        isLinking = true
        linkError = nil
        defer { isLinking = false }

        do {
            guard let syncPair = track.syncPair else {
                throw AppleMusicError.playlistNotFound
            }
            let songId = song.id.rawValue

            // Another cached row may already own this Apple Music track (both
            // playlists contained the song with divergent metadata, so the
            // engine kept two rows). Merge into it instead of adding a
            // duplicate to the playlist and leaving twin rows behind.
            if let existing = fetchCachedTrack(appleMusicTrackId: songId, excluding: track) {
                if existing.spotifyTrackUri == nil {
                    existing.spotifyTrackUri = track.spotifyTrackUri
                }
                existing.source = .both
                existing.syncState = .synced
                existing.unmatchedPlatform = nil
                existing.removalFlag = nil
                existing.removalFlaggedAt = nil
                modelContext.delete(track)
                try? modelContext.save()
                didLink = true
                return
            }

            // Add to the Apple Music playlist — unless this row already points
            // at that exact song, in which case the write would duplicate it.
            if track.appleMusicTrackId != songId {
                let am = AppleMusicManager()
                let playlists = try await am.fetchUserPlaylists()
                if let playlist = playlists.first(where: { $0.id.rawValue == syncPair.appleMusicPlaylistId }) {
                    try await am.addTrack(song, to: playlist)
                } else {
                    throw AppleMusicError.playlistNotFound
                }
            }

            // Update the cached track
            track.appleMusicTrackId = songId
            track.unmatchedPlatform = nil
            track.syncState = .synced
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
        guard !isLinking else { return }
        isLinking = true
        linkError = nil
        defer { isLinking = false }

        do {
            guard let syncPair = track.syncPair else {
                throw SyncError.spotifyPlaylistNotFound
            }

            // Another cached row may already own this Spotify track (both
            // playlists contained the song with divergent metadata, so the
            // engine kept two rows). Merge into it instead of adding a
            // duplicate to the playlist and leaving twin rows behind.
            if let existing = fetchCachedTrack(spotifyTrackUri: spotifyTrack.uri, excluding: track) {
                if existing.appleMusicTrackId == nil {
                    existing.appleMusicTrackId = track.appleMusicTrackId
                }
                existing.source = .both
                existing.syncState = .synced
                existing.unmatchedPlatform = nil
                existing.removalFlag = nil
                existing.removalFlaggedAt = nil
                modelContext.delete(track)
                try? modelContext.save()
                didLink = true
                return
            }

            // Add to the Spotify playlist — unless this row already points at
            // that exact URI, in which case the write would duplicate it.
            if track.spotifyTrackUri != spotifyTrack.uri {
                let client = SpotifyAPIClient()
                try await client.addTracksToPlaylist(
                    playlistId: syncPair.spotifyPlaylistId,
                    trackUris: [spotifyTrack.uri]
                )
            }

            // Update the cached track
            track.spotifyTrackUri = spotifyTrack.uri
            track.unmatchedPlatform = nil
            track.syncState = .synced
            if track.source == .appleMusic {
                track.source = .both
            }
            try? modelContext.save()
            didLink = true
        } catch {
            linkError = "Failed to link: \(error.localizedDescription)"
        }
    }

    /// Finds another cached row of the same SyncPair that already owns the
    /// given platform identifier. Used to merge manual matches instead of
    /// creating duplicate playlist entries.
    @MainActor
    private func fetchCachedTrack(
        spotifyTrackUri: String? = nil,
        appleMusicTrackId: String? = nil,
        excluding current: CachedTrack
    ) -> CachedTrack? {
        guard let pairId = current.syncPair?.id else { return nil }
        let descriptor = FetchDescriptor<CachedTrack>(
            predicate: #Predicate { $0.syncPair?.id == pairId }
        )
        guard let rows = try? modelContext.fetch(descriptor) else { return nil }
        return rows.first { row in
            row.id != current.id &&
            ((spotifyTrackUri != nil && row.spotifyTrackUri == spotifyTrackUri) ||
             (appleMusicTrackId != nil && row.appleMusicTrackId == appleMusicTrackId))
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
