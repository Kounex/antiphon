import AntiphonDesign
import SwiftData
import SwiftUI

/// The home tab: one hero number, then whatever needs the person, then
/// every seam as stitched covers.
struct SyncsHomeView: View {
    let model: SyncsHomeModel
    @Binding var path: [SyncsRoute]
    let accountInitials: String?
    let onAccount: () -> Void
    let onNewSeam: () -> Void
    let onSyncNow: (UUID) -> Void

    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var unlinkCandidate: SeamSummary?

    var body: some View {
        @Bindable var model = model
        List {
            if model.isLoaded && model.seams.isEmpty {
                emptyState.plainRow()
            } else {
                hero.plainRow()
                if let banner = model.reviewBanner {
                    Banner(tone: .review, symbol: "questionmark.circle.fill", title: banner.title, message: banner.message) {
                        Button("Review") { path.append(.seam(banner.firstSeamId)) }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.capsule)
                            .tint(.statusReview)
                            .foregroundStyle(Color.canvas)
                    }
                    .plainRow()
                }
                ChipBar(model.chips, selection: $model.filter).plainRow()
                ForEach(model.visibleSeams) { seam in
                    card(seam).plainRow(vertical: Space.s2)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Syncs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("New seam", systemImage: "plus", action: onNewSeam)
                    .tint(.ink)
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                AccountButton(initials: accountInitials, action: onAccount)
            }
        }
        .refreshable { await model.load() }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                await model.load()
            }
        }
        .confirmationDialog(
            "Unlink \(unlinkCandidate?.name ?? "")?",
            isPresented: Binding(get: { unlinkCandidate != nil }, set: { if !$0 { unlinkCandidate = nil } }),
            titleVisibility: .visible,
            presenting: unlinkCandidate
        ) { seam in
            Button("Unlink playlists", role: .destructive) { Task { await model.unlink(seam.id) } }
        } message: { _ in
            Text("Both playlists stay exactly as they are. Antiphon stops syncing them.")
        }
    }

    // MARK: - Sections

    private var hero: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            let heroLayout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Space.s2 + 2))
            heroLayout {
                // A number never breaks across lines.
                Text(model.tracksInSync.formatted()).metricXL().foregroundStyle(Color.ink)
                    .lineLimit(1).minimumScaleFactor(0.5)
                Text("tracks in sync").font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            .accessibilityElement(children: .combine)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s1 + 2) { heroPill; heroDetail }
                VStack(alignment: .leading, spacing: Space.s1) { heroPill; heroDetail }
            }
        }
    }

    @ViewBuilder private var heroPill: some View {
        if model.watchingCount > 0 { StatusPill(.watching(model.watchingCount)) }
    }

    private var heroDetail: some View {
        Text(model.heroDetail).font(.footnote).foregroundStyle(Color.inkMuted)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text("No seams yet.").font(.antiphonTitle2).foregroundStyle(Color.ink)
            Text("Pick a playlist on one side and Antiphon will find or create its twin on the other.")
                .font(.body).foregroundStyle(Color.inkMuted)
            Button("New seam", systemImage: "plus", action: onNewSeam).glassButton(.primary)
        }
        .padding(.top, Space.s8)
    }

    private func card(_ seam: SeamSummary) -> some View {
        let covers = SeamPresentation.covers(seam, size: 56)
        return Button { path.append(.seam(seam.id)) } label: {
            SyncCard(
                title: seam.name,
                subtitle: model.subtitle(for: seam),
                leading: covers.0, trailing: covers.1,
                direction: SeamPresentation.direction(seam.direction),
                health: SeamPresentation.health(seam.counts),
                status: .init(isMonitoring: seam.isMonitored, isSyncing: syncCoordinator.isSyncing(seam.id),
                              isPaused: seam.isPaused, failure: model.failure(for: seam))
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the seam")
        .swipeActions(edge: .leading) {
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { onSyncNow(seam.id) }
                .tint(.thread)
        }
        .swipeActions(edge: .trailing) {
            Button("Unlink", systemImage: "link.badge.minus", role: .destructive) { unlinkCandidate = seam }
            Button(seam.isPaused ? "Resume" : "Pause", systemImage: seam.isPaused ? "play.fill" : "pause.fill") {
                Task { await model.setPaused(!seam.isPaused, seamId: seam.id) }
            }
            .tint(.inkMuted)
        }
        .contextMenu {
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { onSyncNow(seam.id) }
            Button(seam.isPaused ? "Resume" : "Pause", systemImage: seam.isPaused ? "play.fill" : "pause.fill") {
                Task { await model.setPaused(!seam.isPaused, seamId: seam.id) }
            }
            Button("Rules", systemImage: "slider.horizontal.3") { path.append(.rules(seam.id)) }
            Button("Unlink", systemImage: "link.badge.minus", role: .destructive) { unlinkCandidate = seam }
        } preview: {
            SeamPreviewCard(seam: seam)
        }
    }
}

/// The long-press preview: the seam's hero at a glance.
private struct SeamPreviewCard: View {
    let seam: SeamSummary

    var body: some View {
        let covers = SeamPresentation.covers(seam, size: 96)
        VStack(spacing: Space.s4) {
            SeamLine(leading: covers.0, trailing: covers.1, direction: SeamPresentation.direction(seam.direction),
                     isMonitoring: seam.isMonitored && !seam.isPaused, style: .hero)
            Text(seam.name).font(.antiphonTitle2).foregroundStyle(Color.ink)
            Text(SeamDetailModel.headerDetail(for: seam)).font(.footnote).foregroundStyle(Color.inkMuted)
            StatTiles([
                StatTile(seam.counts.synced, "In sync", tint: .statusSynced),
                StatTile(seam.counts.review, "To review", tint: .statusReview),
                StatTile(seam.counts.missing, "Not available")
            ])
        }
        .padding(Space.s5)
        .frame(width: 340)
        .background(Color.canvas)
    }
}

extension View {
    /// A full-width list row with no background or separator.
    func plainRow(vertical: CGFloat = Space.s1 + 2) -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: vertical, leading: Space.s4, bottom: vertical, trailing: Space.s4))
    }
}
