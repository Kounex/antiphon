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

/// Shows the sync log history for a SyncPair, grouped by date with
/// collapsed no-op runs, filter chips, and pagination.
struct HistoryTabView: View {
    let syncPair: SyncPair

    @Query private var logs: [SyncLog]
    @State private var activeFilter: HistoryFilter = .all
    @State private var displayLimit = 50

    init(syncPair: SyncPair) {
        self.syncPair = syncPair
        let pairId = syncPair.id
        let predicate = #Predicate<SyncLog> { $0.syncPair?.id == pairId }
        _logs = Query(filter: predicate, sort: \.timestamp, order: .reverse)
    }

    private var filteredLogs: [SyncLog] {
        switch activeFilter {
        case .all: return logs
        case .failures: return logs.filter { $0.isFailed }
        case .action(let action): return logs.filter { $0.action == action }
        }
    }
    
    private var failureCount: Int {
        logs.filter { $0.isFailed }.count
    }
    
    private var latestSyncFailed: Bool {
        logs.first?.isFailed == true
    }

    private var sections: [HistorySection] {
        HistorySection.build(from: Array(filteredLogs.prefix(displayLimit)))
    }

    private var hasMore: Bool {
        filteredLogs.count > displayLimit
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
                    LazyVStack(spacing: 0) {
                        filterChips
                            .padding(.bottom, 12)
                        
                        if activeFilter == .all, latestSyncFailed {
                            failureBanner
                                .padding(.bottom, 12)
                        }

                        ForEach(sections) { section in
                            sectionHeader(section.title)

                            ForEach(section.items) { item in
                                switch item {
                                case .single(let log):
                                    SyncLogRow(log: log)
                                        .padding(.bottom, 8)
                                case .collapsed(let logs):
                                    CollapsedSyncRow(logs: logs)
                                        .padding(.bottom, 8)
                                }
                            }
                        }

                        if hasMore {
                            Button {
                                withAnimation { displayLimit += 50 }
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.appCaption)
                                    Text("Show Earlier History")
                                        .font(.appCaptionBold)
                                }
                                .foregroundStyle(Color.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.surfaceElevated.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                            }
                            .buttonStyle(.plain)
                            .padding(.top, 4)
                        }
                    }
                    .padding()
                }
            }
        }
    }

    // MARK: - Filter Chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                FilterChip(label: "All", isActive: activeFilter == .all) {
                    withAnimation { activeFilter = .all; displayLimit = 50 }
                }
                if failureCount > 0 {
                    FilterChip(
                        label: latestSyncFailed ? "Failures (\(failureCount))" : "Failures",
                        isActive: activeFilter == .failures,
                        isDestructive: latestSyncFailed
                    ) {
                        withAnimation { activeFilter = .failures; displayLimit = 50 }
                    }
                }
                FilterChip(label: "Manual", isActive: activeFilter == .action(.manualSync)) {
                    withAnimation { activeFilter = .action(.manualSync); displayLimit = 50 }
                }
                FilterChip(label: "Monitor", isActive: activeFilter == .action(.monitorSync)) {
                    withAnimation { activeFilter = .action(.monitorSync); displayLimit = 50 }
                }
                FilterChip(label: "Delta", isActive: activeFilter == .action(.deltaSync)) {
                    withAnimation { activeFilter = .action(.deltaSync); displayLimit = 50 }
                }
                FilterChip(label: "Rebuild", isActive: activeFilter == .action(.fullRebuild)) {
                    withAnimation { activeFilter = .action(.fullRebuild); displayLimit = 50 }
                }
            }
        }
    }

    // MARK: - Failure Banner
    
    private var failureBanner: some View {
        Button {
            withAnimation { activeFilter = .failures; displayLimit = 50 }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color.syncError)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(failureCount) sync failure\(failureCount == 1 ? "" : "s") detected")
                        .font(.appCaptionBold)
                        .foregroundStyle(Color.syncError)
                    Text("Tap to review — this may need your attention.")
                        .font(.appMicro)
                        .foregroundStyle(Color.textSecondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.syncError.opacity(0.6))
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.syncError.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.syncError.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
    
    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.appCaptionBold)
                .foregroundStyle(Color.textTertiary)
            Spacer()
        }
        .padding(.vertical, 8)
    }
}

// MARK: - History Filter

private enum HistoryFilter: Equatable {
    case all
    case failures
    case action(SyncAction)
}

// MARK: - Filter Chip

private struct FilterChip: View {
    let label: String
    let isActive: Bool
    var isDestructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.appCaptionBold)
                .foregroundStyle(chipForeground)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(chipBackground)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
    
    private var chipForeground: Color {
        if isActive && isDestructive { return .white }
        if isActive { return .white }
        if isDestructive { return .syncError }
        return .textSecondary
    }
    
    private var chipBackground: Color {
        if isActive && isDestructive { return .syncError.opacity(0.7) }
        if isActive { return .white.opacity(0.15) }
        if isDestructive { return .syncError.opacity(0.1) }
        return .surfaceElevated
    }
}

// MARK: - History Section Model

/// Groups logs into date-based sections with collapsed no-op runs.
struct HistorySection: Identifiable {
    let id: String
    let title: String
    let items: [HistoryItem]

    enum HistoryItem: Identifiable {
        case single(SyncLog)
        case collapsed([SyncLog])

        var id: String {
            switch self {
            case .single(let log): return log.id.uuidString
            case .collapsed(let logs): return "collapsed-\(logs.first?.id.uuidString ?? UUID().uuidString)"
            }
        }
    }

    static func build(from logs: [SyncLog]) -> [HistorySection] {
        let calendar = Calendar.current
        let now = Date()

        let grouped: [(key: DateGroup, logs: [SyncLog])] = {
            var result: [(key: DateGroup, logs: [SyncLog])] = []
            for log in logs {
                let group = DateGroup.from(log.timestamp, calendar: calendar, now: now)
                if let last = result.last, last.key == group {
                    result[result.count - 1].logs.append(log)
                } else {
                    result.append((key: group, logs: [log]))
                }
            }
            return result
        }()

        return grouped.map { group in
            HistorySection(
                id: group.key.id,
                title: group.key.title,
                items: collapseNoOps(group.logs)
            )
        }
    }

    private static func collapseNoOps(_ logs: [SyncLog]) -> [HistoryItem] {
        var items: [HistoryItem] = []
        var noOpRun: [SyncLog] = []

        func flushNoOps() {
            guard !noOpRun.isEmpty else { return }
            if noOpRun.count == 1 {
                items.append(.single(noOpRun[0]))
            } else {
                items.append(.collapsed(noOpRun))
            }
            noOpRun = []
        }

        for log in logs {
            if log.isNoOp && !log.isFailed {
                noOpRun.append(log)
            } else {
                flushNoOps()
                items.append(.single(log))
            }
        }
        flushNoOps()
        return items
    }
}

// MARK: - Date Grouping

private enum DateGroup: Equatable {
    case today
    case yesterday
    case thisWeek
    case earlier(month: Int, year: Int)

    var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .thisWeek: return "This Week"
        case .earlier(let month, let year):
            let formatter = DateFormatter()
            formatter.dateFormat = "MMMM yyyy"
            var components = DateComponents()
            components.month = month
            components.year = year
            if let date = Calendar.current.date(from: components) {
                return formatter.string(from: date)
            }
            return "\(month)/\(year)"
        }
    }

    var id: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .thisWeek: return "thisWeek"
        case .earlier(let month, let year): return "earlier-\(year)-\(month)"
        }
    }

    static func from(_ date: Date, calendar: Calendar, now: Date) -> DateGroup {
        if calendar.isDateInToday(date) { return .today }
        if calendar.isDateInYesterday(date) { return .yesterday }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) { return .thisWeek }
        let components = calendar.dateComponents([.month, .year], from: date)
        return .earlier(month: components.month ?? 1, year: components.year ?? 2026)
    }
}

// MARK: - Collapsed Sync Row

struct CollapsedSyncRow: View {
    let logs: [SyncLog]
    @State private var isExpanded = false

    private var timeRange: String {
        guard let newest = logs.first?.timestamp,
              let oldest = logs.last?.timestamp else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        if Calendar.current.isDate(newest, inSameDayAs: oldest) {
            return "\(formatter.string(from: oldest)) – \(formatter.string(from: newest))"
        }
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "MMM d"
        return "\(dayFormatter.string(from: oldest)) – \(dayFormatter.string(from: newest))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.surfaceElevated)
                            .frame(width: 40, height: 40)

                        Image(systemName: "checkmark.circle")
                            .font(.appCaption)
                            .foregroundStyle(Color.textTertiary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("\(logs.count) syncs with no changes")
                                .font(.appBodyBold)
                                .foregroundStyle(Color.textSecondary)
                        }

                        Text(timeRange)
                            .font(.appCaption)
                            .foregroundStyle(Color.textTertiary)
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.textTertiary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .glassCard(padding: 12)
            }
            .buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 6) {
                    ForEach(logs) { log in
                        SyncLogRow(log: log)
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .clipped()
        .animation(.easeInOut(duration: 0.25), value: isExpanded)
    }
}

// MARK: - Sync Log Row

struct SyncLogRow: View {
    let log: SyncLog

    private var isFailed: Bool { log.isFailed }

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(isFailed ? Color.syncError.opacity(0.15) : Color.surfaceElevated)
                    .frame(width: 40, height: 40)

                Image(systemName: isFailed ? "xmark.circle.fill" : log.action.icon)
                    .font(.appCaption)
                    .foregroundStyle(isFailed ? Color.syncError : Color.textSecondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(isFailed ? "Sync Failed" : log.action.label)
                        .font(.appBodyBold)
                        .foregroundStyle(isFailed ? Color.syncError : Color.textPrimary)

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

                    if log.isNoOp && !isFailed {
                        Text("No changes")
                            .font(.appCaption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }

                if let details = log.details {
                    Text(details)
                        .font(.appCaption)
                        .foregroundStyle(isFailed ? Color.syncError.opacity(0.8) : Color.textTertiary)
                        .lineLimit(3)
                }
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(isFailed ? Color.syncError.opacity(0.06) : Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isFailed ? Color.syncError.opacity(0.2) : .clear, lineWidth: 1)
                )
        )
    }
}
