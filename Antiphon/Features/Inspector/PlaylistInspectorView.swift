import SwiftUI
import SwiftData

/// A detailed inspector view for a single SyncPair, showing track comparison,
/// flagged removals, sync history, and manual sync controls.
struct PlaylistInspectorView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(SpotifyAuthManager.self) private var spotifyAuth
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Bindable var syncPair: SyncPair

    @State private var selectedTab: InspectorTab = .tracks
    @State private var showDeleteConfirmation = false
    @State private var isPendingDeletion = false

    @Query private var tracks: [CachedTrack]

    init(syncPair: SyncPair) {
        self._syncPair = Bindable(wrappedValue: syncPair)
        let pairId = syncPair.id
        let predicate = #Predicate<CachedTrack> { $0.syncPair?.id == pairId }
        _tracks = Query(filter: predicate)
    }

    var body: some View {
        ZStack {
            Color.appBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header card
                headerCard
                    .padding(.horizontal)
                    .padding(.top, 8)

                // Tab bar
                tabBar
                    .padding(.top, 12)

                // Tab content
                TabView(selection: $selectedTab) {
                    TracksTabView(syncPair: syncPair)
                        .tag(InspectorTab.tracks)

                    FlaggedTabView(syncPair: syncPair)
                        .tag(InspectorTab.flagged)

                    HistoryTabView(syncPair: syncPair)
                        .tag(InspectorTab.history)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 2) {
                    Text(syncPair.spotifyPlaylistName)
                        .font(.appCaptionBold)
                        .foregroundStyle(Color.textPrimary)
                    Text(syncPair.syncDirection.rawValue)
                        .font(.appMicro)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        syncCoordinator.startSync(
                            pairId: syncPair.id,
                            action: .manualSync,
                            spotifyAuth: spotifyAuth
                        )
                    } label: {
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(syncCoordinator.isSyncing(syncPair.id))

                    Button {
                        syncCoordinator.startSync(
                            pairId: syncPair.id,
                            action: .fullRebuild,
                            spotifyAuth: spotifyAuth
                        )
                    } label: {
                        Label("Full Rebuild", systemImage: "arrow.clockwise.square")
                    }
                    .disabled(syncCoordinator.isSyncing(syncPair.id))

                    Divider()

                    Toggle(isOn: $syncPair.isMonitored) {
                        Label("Monitor", systemImage: "eye")
                    }

                    Divider()

                    ShareLink(item: generateDiagnosticReport()) {
                        Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                    }

                    Divider()

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Unlink Playlists", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .alert("Unlink Playlists?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Unlink", role: .destructive) {
                isPendingDeletion = true
                syncCoordinator.cancelSync(pairId: syncPair.id)
                dismiss()
            }
        } message: {
            Text("This will stop syncing between these playlists. No tracks will be deleted from either platform.")
        }
        .onDisappear {
            if isPendingDeletion {
                isPendingDeletion = false
                modelContext.delete(syncPair)
                try? modelContext.save()
            }
        }
    }

    // MARK: - Header Card

    private var headerCard: some View {
        VStack(spacing: 14) {
            // Platform link row
            HStack(spacing: 12) {
                // Spotify side
                VStack(spacing: 6) {
                    PlatformBadge(platform: .spotify, size: .regular)
                    Text(syncPair.spotifyPlaylistName)
                        .font(.appCaption)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)

                // Arrow
                Image(systemName: syncPair.syncDirection.icon)
                    .font(.appBody)
                    .foregroundStyle(Color.textTertiary)

                // Apple Music side
                VStack(spacing: 6) {
                    PlatformBadge(platform: .appleMusic, size: .regular)
                    Text(syncPair.appleMusicPlaylistName)
                        .font(.appCaption)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
            }

            // Stats row
            HStack(spacing: 0) {
                StatPill(
                    label: "Tracks",
                    value: "\(tracks.count)",
                    color: .syncProgress
                )

                StatPill(
                    label: "Attention",
                    value: "\(tracks.filter { $0.needsAttention }.count)",
                    color: tracks.contains(where: { $0.unmatchedPlatform != nil }) ? .syncError : .syncWarning
                )

                StatPill(
                    label: "Last Sync",
                    value: syncPair.lastSyncedAt?.relativeDescription ?? "Never",
                    color: .syncSuccess
                )
            }

            // Sync status — dynamic based on coordinator state
            if syncCoordinator.isSyncing(syncPair.id) {
                // In-progress banner with live progress
                let progress = syncCoordinator.syncProgress[syncPair.id]
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color.syncProgress)
                            .scaleEffect(0.8)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Syncing…")
                                .font(.appCaptionBold)
                                .foregroundStyle(Color.syncProgress)
                            
                            if let progress, progress.totalTracks > 0 {
                                Text("\(progress.summary) tracks")
                                    .font(.appMicro)
                                    .foregroundStyle(Color.textTertiary)
                            }
                        }

                        Spacer()

                        Button {
                            syncCoordinator.cancelSync(pairId: syncPair.id)
                        } label: {
                            Text("Cancel")
                                .font(.appCaptionBold)
                                .foregroundStyle(Color.syncError)
                        }
                    }
                    
                    // Progress bar
                    if let progress, progress.totalTracks > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.surfaceElevated)
                                    .frame(height: 3)
                                
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(Color.syncProgress)
                                    .frame(width: geo.size.width * progress.fraction, height: 3)
                                    .animation(.easeInOut(duration: 0.3), value: progress.fraction)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color.syncProgress.opacity(0.08))
                )
            } else if let result = syncCoordinator.lastResults[syncPair.id] {
                // Just-finished result banner
                HStack(spacing: 8) {
                    Image(systemName: result.isSuccess ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(result.isSuccess ? Color.syncSuccess : Color.syncError)

                    Text(result.message ?? (result.isSuccess ? "Sync complete" : "Sync failed"))
                        .font(.appCaption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(2)

                    Spacer()

                    if syncPair.isMonitored {
                        HStack(spacing: 4) {
                            PulsingDot(color: .syncSuccess, size: 6)
                            Text("Monitoring")
                                .font(.appMicro)
                                .foregroundStyle(Color.syncSuccess)
                        }
                    }
                }
            } else if let currentStatus = currentSyncStatus {
                // Normal idle status
                HStack(spacing: 8) {
                    SyncStatusIndicator(
                        status: currentStatus,
                        message: currentSyncMessage
                    )

                    Spacer()

                    if syncPair.isMonitored {
                        HStack(spacing: 4) {
                            PulsingDot(color: .syncSuccess, size: 6)
                            Text("Monitoring")
                                .font(.appMicro)
                                .foregroundStyle(Color.syncSuccess)
                        }
                    }
                }
            }
        }
        .glassCard()
    }

    // MARK: - Tab Bar

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(InspectorTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedTab = tab
                    }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: tab.icon)
                                .font(.appCaption)
                            Text(tab.title)
                                .font(.appCaptionBold)

                            if tab == .flagged {
                                let attentionCount = tracks.filter { $0.needsAttention }.count
                                if attentionCount > 0 {
                                    let hasUnmatched = tracks.contains { $0.unmatchedPlatform != nil }
                                    Text("\(attentionCount)")
                                        .font(.appMicro)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(hasUnmatched ? Color.syncError : Color.syncWarning))
                                }
                            }
                        }
                        .foregroundStyle(selectedTab == tab ? Color.textPrimary : Color.textTertiary)

                        Rectangle()
                            .fill(selectedTab == tab ? AnyShapeStyle(AppGradients.brand) : AnyShapeStyle(Color.clear))
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal)
    }

    private var currentSyncStatus: SyncResultStatus? {
        if syncPair.lastSyncedAt == nil && tracks.isEmpty {
            return nil
        }
        let flaggedCount = tracks.filter { $0.removalFlag != nil }.count
        let unmatchedCount = tracks.filter { $0.unmatchedPlatform != nil || $0.effectiveSyncState == .failed }.count
        
        if unmatchedCount > 0 {
            return .failed
        } else if flaggedCount > 0 {
            return .partial
        } else {
            return .success
        }
    }

    private var currentSyncMessage: String {
        let totalCount = tracks.count
        if totalCount == 0 {
            return "No tracks in playlist"
        }
        let flaggedCount = tracks.filter { $0.removalFlag != nil }.count
        let unmatchedCount = tracks.filter { $0.unmatchedPlatform != nil || $0.effectiveSyncState == .failed }.count
        let syncedCount = totalCount - flaggedCount - unmatchedCount
        
        if unmatchedCount == 0 && flaggedCount == 0 {
            return "All \(totalCount) tracks in sync"
        }
        
        var parts: [String] = []
        if flaggedCount > 0 {
            parts.append("\(flaggedCount) flagged")
        }
        if unmatchedCount > 0 {
            parts.append("\(unmatchedCount) missing")
        }
        if syncedCount > 0 {
            parts.append("\(syncedCount) synced")
        }
        
        return parts.joined(separator: ", ")
    }

    private func generateDiagnosticReport() -> String {
        var report = "=== ANTIPHON SYNC DIAGNOSTICS ===\n"
        report += "Date: \(Date().description)\n"
        report += "Pair ID: \(syncPair.id.uuidString)\n"
        report += "Spotify Playlist: \(syncPair.spotifyPlaylistName) (\(syncPair.spotifyPlaylistId))\n"
        report += "Apple Music Playlist: \(syncPair.appleMusicPlaylistName) (\(syncPair.appleMusicPlaylistId))\n"
        report += "Direction: \(syncPair.syncDirection.rawValue)\n"
        report += "Last Synced At: \(syncPair.lastSyncedAt?.description ?? "Never")\n"
        report += "Last Result: \(syncPair.lastSyncResult?.rawValue ?? "None")\n"
        report += "Last Message: \(syncPair.lastSyncMessage ?? "None")\n"
        report += "\n=== TRACKS CACHE (\(tracks.count) tracks) ===\n"
        
        for (index, track) in tracks.enumerated() {
            report += "\(index + 1). Title: \(track.title)\n"
            report += "   Artist: \(track.artist)\n"
            report += "   ISRC: \(track.isrc)\n"
            report += "   Spotify URI: \(track.spotifyTrackUri ?? "nil")\n"
            report += "   Apple Music ID: \(track.appleMusicTrackId ?? "nil")\n"
            report += "   Source: \(track.source.rawValue)\n"
            report += "   Sync State: \(track.effectiveSyncState.rawValue)\n"
            if let removalFlag = track.removalFlag {
                report += "   Removal Flag: \(removalFlag.rawValue) (flagged at \(track.removalFlaggedAt?.description ?? "nil"))\n"
            }
            if let unmatchedPlatform = track.unmatchedPlatform {
                report += "   Unmatched Platform: \(unmatchedPlatform.rawValue)\n"
            }
            report += "   Added At: \(track.addedAt.description)\n"
            report += "\n"
        }
        
        return report
    }
}

// MARK: - Inspector Tab

enum InspectorTab: CaseIterable {
    case tracks, flagged, history

    var title: String {
        switch self {
        case .tracks: return "Tracks"
        case .flagged: return "Flagged"
        case .history: return "History"
        }
    }

    var icon: String {
        switch self {
        case .tracks: return "music.note.list"
        case .flagged: return "flag.fill"
        case .history: return "clock.arrow.circlepath"
        }
    }
}

// MARK: - Stat Pill

struct StatPill: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.appTitle3)
                .foregroundStyle(color)

            Text(label)
                .font(.appMicro)
                .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
    }
}
