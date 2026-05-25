import SwiftUI
import SwiftData

/// Tracks tab — shows all cached tracks for a SyncPair with source/target status indicators.
struct TracksTabView: View {
    let syncPair: SyncPair
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            // Search
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.textTertiary)
                TextField("Search tracks…", text: $searchQuery)
                    .font(.appBody)
                    .foregroundStyle(Color.textPrimary)
                    .autocorrectionDisabled()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.surfaceElevated))
            .padding(.horizontal)
            .padding(.top, 8)

            TracksListContainer(syncPair: syncPair, searchQuery: searchQuery)
        }
    }
}

struct TracksListContainer: View {
    let syncPair: SyncPair
    let searchQuery: String
    @Environment(SyncCoordinator.self) private var syncCoordinator

    @Query private var tracks: [CachedTrack]

    init(syncPair: SyncPair, searchQuery: String) {
        self.syncPair = syncPair
        self.searchQuery = searchQuery
        let pairId = syncPair.id
        
        let predicate = #Predicate<CachedTrack> { $0.syncPair?.id == pairId }
        _tracks = Query(filter: predicate, sort: \.addedAt, order: .forward)
    }

    private var filteredTracks: [CachedTrack] {
        if searchQuery.isEmpty { return tracks }
        return tracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchQuery) ||
            $0.artist.localizedCaseInsensitiveContains(searchQuery) ||
            $0.isrc.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    var body: some View {
        if filteredTracks.isEmpty {
            emptyView
        } else {
            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(filteredTracks) { track in
                        TrackRow(track: track)
                    }
                }
                .padding()
            }
        }
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Spacer()
            if syncCoordinator.isSyncing(syncPair.id) {
                ProgressView()
                    .tint(Color.syncProgress)
                    .scaleEffect(1.2)
                Text("Loading tracks…")
                    .font(.appBody)
                    .foregroundStyle(Color.textSecondary)
                Text("The track list will appear shortly.")
                    .font(.appCaption)
                    .foregroundStyle(Color.textTertiary)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.textTertiary)
                Text(searchQuery.isEmpty ? "No cached tracks yet" : "No matching tracks")
                    .font(.appBody)
                    .foregroundStyle(Color.textSecondary)
                Text(searchQuery.isEmpty ? "Run an initial sync to populate tracks." : "Try a different search term.")
                    .font(.appCaption)
                    .foregroundStyle(Color.textTertiary)
            }
            Spacer()
        }
    }
}

// MARK: - Track Row

struct TrackRow: View {
    @Environment(\.modelContext) private var modelContext
    let track: CachedTrack
    @State private var showManualMatch = false
    @State private var showDismissConfirmation = false

    var body: some View {
        Button {
            if track.unmatchedPlatform != nil {
                showManualMatch = true
            }
        } label: {
            HStack(spacing: 12) {
                TrackArtworkView(url: track.artworkURL, size: 44, cornerRadius: 8)

                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title)
                        .font(.appBody)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Text(track.artist)
                            .font(.appCaption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)

                        if let album = track.albumName {
                            Text("•")
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                            Text(album)
                                .font(.appCaption)
                                .foregroundStyle(Color.textTertiary)
                                .lineLimit(1)
                        }
                    }

                    // Status label for problematic tracks
                    if let unmatched = track.unmatchedPlatform {
                        Text(unmatched.description)
                            .font(.appMicro)
                            .foregroundStyle(Color.syncError)
                    } else if let removalDescription = track.removalDescription {
                        Text(removalDescription)
                            .font(.appMicro)
                            .foregroundStyle(Color.syncWarning)
                    }
                }

                Spacer()

                // Source → Target sync status dots or Dismiss button
                if track.unmatchedPlatform != nil {
                    Button {
                        showDismissConfirmation = true
                    } label: {
                        Text("Dismiss")
                            .font(.appCaption)
                            .bold()
                            .padding(.vertical, 6)
                            .padding(.horizontal, 10)
                            .background(Color.syncSuccess.opacity(0.12))
                            .foregroundStyle(Color.syncSuccess)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                } else {
                    HStack(spacing: 3) {
                        StatusDot(status: track.sourceDotStatus)
                        StatusDot(status: track.targetDotStatus)
                    }
                }

                // Chevron for tappable unmatched tracks
                if track.unmatchedPlatform != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.textTertiary.opacity(0.5))
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(rowBackground)
            )
        }
        .buttonStyle(.plain)
        .alert("Dismiss Mismatch?", isPresented: $showDismissConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Dismiss", role: .none) {
                withAnimation {
                    track.unmatchedPlatform = nil
                    track.syncState = .synced
                    try? modelContext.save()
                }
            }
        } message: {
            Text("This will mark the track as synced and ignore the missing match. This action can only be reversed by running a Full Rebuild.")
        }
        .sheet(isPresented: $showManualMatch) {
            if let platform = track.unmatchedPlatform {
                ManualMatchSheet(track: track, targetPlatform: platform)
            }
        }
    }

    private var rowBackground: Color {
        if track.unmatchedPlatform != nil {
            return Color.syncError.opacity(0.06)
        } else if track.removalFlag != nil {
            return Color.syncWarning.opacity(0.05)
        }
        return .clear
    }
}

// MARK: - Status Dot

struct StatusDot: View {
    let status: PlatformSyncStatus

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(dotColor)
            .frame(width: 8, height: 8)
            .opacity(status == .syncing ? (isPulsing ? 0.3 : 1.0) : 1.0)
            .overlay {
                if status == .unmatched {
                    Circle()
                        .stroke(dotColor.opacity(0.5), lineWidth: 1)
                        .frame(width: 12, height: 12)
                }
            }
            .onAppear {
                if status == .syncing {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                }
            }
            .onChange(of: status) { _, newValue in
                if newValue == .syncing {
                    withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                        isPulsing = true
                    }
                } else {
                    isPulsing = false
                }
            }
    }

    private var dotColor: Color {
        switch status {
        case .synced:
            return .syncSuccess       // Green — confirmed
        case .unmatched:
            return .syncError         // Red — failed to match
        case .flagged:
            return .syncWarning       // Yellow — needs attention
        case .pending, .unknown:
            return .surfaceElevated   // Gray — not yet processed
        case .syncing:
            return .syncProgress      // Blue/teal — in progress
        }
    }
}

/// Shows tracks that need attention: unmatched, destination-only extras, and removal flags.
/// The user can review these and decide to dismiss, remove, or keep.
struct FlaggedTabView: View {
    let syncPair: SyncPair
    @Environment(\.modelContext) private var modelContext

    @Query private var tracks: [CachedTrack]

    init(syncPair: SyncPair) {
        self.syncPair = syncPair
        let pairId = syncPair.id
        let predicate = #Predicate<CachedTrack> { $0.syncPair?.id == pairId }
        _tracks = Query(filter: predicate, sort: \.addedAt, order: .forward)
    }

    private var sourcePlatformName: String {
        switch syncPair.syncDirection {
        case .spotifyToApple, .bidirectional: return "Spotify"
        case .appleToSpotify: return "Apple Music"
        }
    }

    private var targetPlatformName: String {
        switch syncPair.syncDirection {
        case .spotifyToApple, .bidirectional: return "Apple Music"
        case .appleToSpotify: return "Spotify"
        }
    }

    private var unmatchedTracks: [CachedTrack] {
        tracks
            .filter { $0.unmatchedPlatform != nil }
    }

    private var extraOnDestTracks: [CachedTrack] {
        tracks
            .filter { $0.removalFlag == .extraOnDestination }
            .sorted { ($0.removalFlaggedAt ?? .distantPast) > ($1.removalFlaggedAt ?? .distantPast) }
    }

    private var removalFlaggedTracks: [CachedTrack] {
        tracks
            .filter { $0.removalFlag != nil && $0.removalFlag != .extraOnDestination }
            .sorted { ($0.removalFlaggedAt ?? .distantPast) > ($1.removalFlaggedAt ?? .distantPast) }
    }

    private var hasItems: Bool {
        !unmatchedTracks.isEmpty || !extraOnDestTracks.isEmpty || !removalFlaggedTracks.isEmpty
    }

    var body: some View {
        Group {
            if !hasItems {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.syncSuccess)
                    Text("All Tracks Synced")
                        .font(.appBody)
                        .foregroundStyle(Color.textSecondary)
                    Text("No unmatched or flagged tracks.\nEverything is in sync!")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        // Unmatched section
                        if !unmatchedTracks.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.syncError)
                                Text("\(unmatchedTracks.count) track\(unmatchedTracks.count == 1 ? "" : "s") couldn't be found. Tap to manually search and link.")
                                    .font(.appCaption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.syncError.opacity(0.08))
                            )

                            ForEach(unmatchedTracks) { track in
                                TrackRow(track: track)
                            }
                        }

                        // Destination-only extras section
                        if !extraOnDestTracks.isEmpty {
                            let count = extraOnDestTracks.count
                            let suffix = count == 1 ? "" : "s"
                            let bannerText: String = {
                                if syncPair.syncDirection == .bidirectional {
                                    return "\(count) track\(suffix) exist only on \(targetPlatformName). Bidirectional sync has matched them to \(sourcePlatformName), but you can choose to remove them."
                                } else {
                                    return "\(count) track\(suffix) exist only on \(targetPlatformName). Unidirectional sync ignores them, but you can choose to remove them."
                                }
                            }()

                            HStack(spacing: 10) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Color.syncWarning)
                                Text(bannerText)
                                    .font(.appCaption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.syncWarning.opacity(0.08))
                            )

                             ForEach(extraOnDestTracks) { track in
                                 FlaggedTrackRow(track: track) {
                                     // Ignore: clear the flag, treat as in-sync
                                     track.removalFlag = nil
                                     track.removalFlaggedAt = nil
                                     try? modelContext.save()
                                 }
                             }
                        }

                        // Removal flagged section
                        if !removalFlaggedTracks.isEmpty {
                            let bannerText: String = {
                                if syncPair.syncDirection == .bidirectional {
                                    return "These tracks were deleted from one platform. Tap Keep to ignore, or Remove to delete from the other platform."
                                } else {
                                    return "These tracks were deleted from \(sourcePlatformName) (source). Tap Keep to ignore, or Remove to delete from \(targetPlatformName)."
                                }
                            }()

                            HStack(spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(Color.syncWarning)
                                Text(bannerText)
                                    .font(.appCaption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.syncWarning.opacity(0.08))
                            )

                             ForEach(removalFlaggedTracks) { track in
                                 FlaggedTrackRow(track: track) {
                                     track.removalFlag = nil
                                     track.removalFlaggedAt = nil
                                     try? modelContext.save()
                                 }
                             }
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - Flagged Track Row

struct FlaggedTrackRow: View {
    let track: CachedTrack
    let onDismiss: () -> Void
    
    @State private var showConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(url: track.artworkURL, size: 48, cornerRadius: 10)

            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text(track.artist)
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                if let description = track.removalDescription {
                    Text(description)
                        .font(.appMicro)
                        .foregroundStyle(Color.syncWarning)
                }

                if let flaggedAt = track.removalFlaggedAt {
                    Text("Flagged \(flaggedAt.relativeDescription)")
                        .font(.appMicro)
                        .foregroundStyle(Color.textTertiary)
                }
            }

            Spacer()

            Button {
                showConfirmation = true
            } label: {
                Text("Keep")
                    .font(.appCaption)
                    .bold()
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(Color.syncSuccess.opacity(0.12))
                    .foregroundStyle(Color.syncSuccess)
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .glassCard(padding: 12)
        .alert("Keep Track?", isPresented: $showConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Keep", role: .none) {
                withAnimation { onDismiss() }
            }
        } message: {
            Text("This will clear the removal flag and mark the track as in-sync. This action can only be reversed by running a Full Rebuild.")
        }
        .contextMenu {
            Button { showConfirmation = true } label: {
                Label("Dismiss Flag", systemImage: "flag.slash")
            }

            Divider()

            if let isrc = track.isrc as String? {
                Button {} label: {
                    Label("ISRC: \(isrc)", systemImage: "barcode")
                }
            }
        }
    }
}

// MARK: - History Tab

/// Shows the sync log history for a SyncPair.
struct HistoryTabView: View {
    let syncPair: SyncPair

    @Query private var logs: [SyncLog]

    init(syncPair: SyncPair) {
        self.syncPair = syncPair
        let pairId = syncPair.id
        let predicate = #Predicate<SyncLog> { $0.syncPair?.id == pairId }
        _logs = Query(filter: predicate, sort: \.timestamp, order: .reverse)
    }

    var body: some View {
        Group {
            if logs.isEmpty {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.textTertiary)
                    Text("No Sync History")
                        .font(.appBody)
                        .foregroundStyle(Color.textSecondary)
                    Text("Sync events will appear here after the first sync.")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                    Spacer()
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(logs) { log in
                            SyncLogRow(log: log)
                        }
                    }
                    .padding()
                }
            }
        }
    }
}

// MARK: - Sync Log Row

struct SyncLogRow: View {
    let log: SyncLog

    var body: some View {
        HStack(spacing: 14) {
            // Action icon
            ZStack {
                Circle()
                    .fill(Color.surfaceElevated)
                    .frame(width: 40, height: 40)

                Image(systemName: log.action.icon)
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(log.action.label)
                        .font(.appBodyBold)
                        .foregroundStyle(Color.textPrimary)

                    Text(log.timestamp.relativeDescription)
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                }

                HStack(spacing: 12) {
                    if log.tracksAdded > 0 {
                        Label("\(log.tracksAdded)", systemImage: "plus.circle.fill")
                            .font(.appCaption)
                            .foregroundStyle(Color.syncSuccess)
                    }

                    if log.tracksRemoved > 0 {
                        Label("\(log.tracksRemoved)", systemImage: "flag.fill")
                            .font(.appCaption)
                            .foregroundStyle(Color.syncWarning)
                    }

                    if log.tracksFailed > 0 {
                        Label("\(log.tracksFailed)", systemImage: "xmark.circle.fill")
                            .font(.appCaption)
                            .foregroundStyle(Color.syncError)
                    }

                    if log.tracksMatched > 0 {
                        Label("\(log.tracksMatched)", systemImage: "checkmark.circle")
                            .font(.appCaption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }

                if let details = log.details {
                    Text(details)
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                        .lineLimit(2)
                }
            }

            Spacer()
        }
        .glassCard(padding: 12)
    }
}
