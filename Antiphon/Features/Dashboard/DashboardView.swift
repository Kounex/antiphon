import SwiftUI
import SwiftData

/// The main dashboard view showing all linked playlist pairs and their sync status.
struct DashboardView: View {
    @Environment(SpotifyAuthManager.self) private var spotifyAuth
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \SyncPair.createdAt, order: .reverse) private var syncPairs: [SyncPair]

    @State private var showingSettings = false
    @State private var showingLinkWizard = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color.appBackground
                    .ignoresSafeArea()

                if syncPairs.isEmpty {
                    emptyStateView
                } else {
                    syncPairsList
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .foregroundStyle(Color.textSecondary)
                    }
                }

                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Image("AppLogo")
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                        Text("Antiphon")
                            .font(.appTitle3)
                            .foregroundStyle(Color.textPrimary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingLinkWizard = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(Color.spotifyGreen)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .environment(spotifyAuth)
            }
            .sheet(isPresented: $showingLinkWizard) {
                LinkWizardView()
                    .environment(spotifyAuth)
            }
        }
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer()

            // App logo
            ZStack {
                // Glow effect behind logo
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.appleMusicPink.opacity(0.2),
                                Color.spotifyGreen.opacity(0.1),
                                .clear
                            ],
                            center: .center,
                            startRadius: 30,
                            endRadius: 90
                        )
                    )
                    .frame(width: 180, height: 180)

                Image("AppLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 110, height: 110)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .shadow(color: Color.appleMusicPink.opacity(0.3), radius: 20, y: 4)
            }

            VStack(spacing: 8) {
                Text("No Linked Playlists")
                    .font(.appTitle)
                    .foregroundStyle(Color.textPrimary)

                Text("Connect your Spotify and Apple Music\nplaylists to keep them in sync.")
                    .font(.appBody)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }

            Button {
                showingLinkWizard = true
            } label: {
                HStack {
                    Image(systemName: "link.badge.plus")
                    Text("Link Your First Playlist")
                }
            }
            .buttonStyle(.antiphon)
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
        .padding()
    }

    // MARK: - Sync Pairs List

    private var syncPairsList: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(syncPairs) { pair in
                    NavigationLink {
                        PlaylistInspectorView(syncPair: pair)
                            .environment(spotifyAuth)
                    } label: {
                        SyncPairRow(syncPair: pair)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }
}

// MARK: - Sync Pair Row

/// A compact card displaying a linked playlist pair's status at a glance.
struct SyncPairRow: View {
    let syncPair: SyncPair
    @Environment(SyncCoordinator.self) private var syncCoordinator

    @Query private var tracks: [CachedTrack]

    init(syncPair: SyncPair) {
        self.syncPair = syncPair
        let pairId = syncPair.id
        let predicate = #Predicate<CachedTrack> { $0.syncPair?.id == pairId }
        _tracks = Query(filter: predicate)
    }

    private var overallStatus: PlatformSyncStatus {
        if syncCoordinator.isSyncing(syncPair.id) {
            return .syncing
        }
        if syncPair.lastSyncedAt == nil || tracks.isEmpty {
            return .unknown
        }
        if tracks.contains(where: { $0.unmatchedPlatform != nil || $0.effectiveSyncState == .failed }) {
            return .unmatched
        }
        if tracks.contains(where: { $0.removalFlag != nil }) {
            return .flagged
        }
        return .synced
    }

    private var statusColor: Color {
        switch overallStatus {
        case .synced: return .syncSuccess
        case .flagged: return .syncWarning
        case .unmatched: return .syncError
        case .syncing: return .syncProgress
        case .pending, .unknown: return .textTertiary.opacity(0.5)
        }
    }

    private var progressSummaryText: String {
        let total = tracks.count
        let synced = tracks.filter { $0.unmatchedPlatform == nil && $0.effectiveSyncState != .failed && $0.removalFlag == nil }.count
        return "\(synced)/\(total)"
    }

    @ViewBuilder
    private var subtitleText: some View {
        switch overallStatus {
        case .synced:
            HStack(spacing: 6) {
                Text("In sync")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncSuccess)
                if !tracks.isEmpty {
                    Text("•")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                    Text(progressSummaryText)
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
        case .flagged:
            HStack(spacing: 6) {
                Text("Partially synced")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncWarning)
                if !tracks.isEmpty {
                    Text("•")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                    Text(progressSummaryText)
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
        case .unmatched:
            HStack(spacing: 6) {
                Text("Partially synced, missing songs")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncError)
                if !tracks.isEmpty {
                    Text("•")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                    Text(progressSummaryText)
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
        case .syncing:
            if let progress = syncCoordinator.syncProgress[syncPair.id],
               progress.totalTracks > 0 {
                Text("Syncing \(progress.summary)")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncProgress)
            } else {
                Text("Syncing…")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncProgress)
            }
        case .pending, .unknown:
            HStack(spacing: 6) {
                Text("Not synced")
                    .font(.appCaption)
                    .foregroundStyle(Color.textTertiary)
                if !tracks.isEmpty {
                    Text("•")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                    Text(progressSummaryText)
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                }
            }
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // Platform badges
            HStack(spacing: -6) {
                PlatformBadge(platform: .spotify, size: .small)
                PlatformBadge(platform: .appleMusic, size: .small)
            }

            // Playlist info
            VStack(alignment: .leading, spacing: 4) {
                Text(syncPair.spotifyPlaylistName)
                    .font(.appTitle3)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                if syncCoordinator.isSyncing(syncPair.id) {
                    HStack(spacing: 6) {
                        ProgressView()
                            .tint(Color.syncProgress)
                            .scaleEffect(0.6)
                        subtitleText
                    }
                } else {
                    subtitleText
                }
            }

            Spacer()

            // Status indicator dot
            if overallStatus == .unknown || overallStatus == .pending {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .frame(width: 20, height: 20) // Match PulsingDot frame bounds
            } else {
                PulsingDot(color: statusColor, size: 8)
            }

            // Sync direction badge
            Image(systemName: syncPair.syncDirection.icon)
                .font(.appCaption)
                .foregroundStyle(Color.textTertiary)

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.textTertiary.opacity(0.5))
        }
        .glassCard()
    }
}

#Preview {
    DashboardView()
        .environment(SpotifyAuthManager())
        .modelContainer(
            try! ModelContainer(
                for: SyncPair.self, CachedTrack.self, SyncLog.self,
                configurations: ModelConfiguration(isStoredInMemoryOnly: true)
            )
        )
}
