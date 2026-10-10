import AntiphonDesign
import SwiftData
import SwiftUI

/// One seam: the covers run under the glass toolbar, tiles summarize health,
/// chips filter the list, and each track's symbol says where it stands.
struct SeamDetailView: View {
    @State var model: SeamDetailModel
    @Binding var path: [SyncsRoute]
    let onSyncNow: (UUID) -> Void
    @State private var heroOpacity: Double = 1

    var body: some View {
        ScrollViewReader { proxy in
            content
                #if DEBUG
                .task(id: model.visibleTracks.count) {
                    guard DebugRoute.startScrolled, let last = model.visibleTracks.last else { return }
                    try? await Task.sleep(for: .milliseconds(300))
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                #endif
        }
    }

    private var content: some View {
        @Bindable var model = model
        return List {
            if let seam = model.detail?.summary {
                header(seam).plainRow()
                StatTiles([
                    StatTile(model.tiles.inSync, "In sync", tint: .statusSynced),
                    StatTile(model.tiles.toReview, "To review", tint: .statusReview),
                    StatTile(model.tiles.unavailable, "Not available")
                ])
                .plainRow()
                actions(seam).plainRow()
                ChipBar(model.chips, selection: $model.filter).plainRow()
                Section {
                    ForEach(model.visibleTracks) { track in
                        AntiphonDesign.TrackRow(
                            title: track.title,
                            detail: SeamPresentation.trackDetail(track),
                            artwork: CoverArt(url: track.artworkURL, seed: track.title, size: 40,
                                              service: SeamPresentation.service(track.origin)),
                            state: SeamPresentation.trackState(track.state),
                            isNew: track.isNew
                        )
                        .accessibilityLabel("\(track.title), \(SeamPresentation.trackDetail(track)), from \(track.origin.rawValue)")
                        .listRowBackground(Color.canvasRaised)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) { heroBackground }
        .background(Color.canvas)
        // A frosted bar once rows scroll under the title; the hero art fades
        // as the list moves, so it only shows behind the toolbar at the top.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
            heroOpacity = max(0, min(1, 1 - offset / 260))
        }

        .navigationTitle(model.detail?.summary.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { onSyncNow(model.seamId) }
                    .tint(.ink)
                Menu("More", systemImage: "ellipsis") {
                    Button("Rules", systemImage: "slider.horizontal.3") { path.append(.rules(model.seamId)) }
                }
            }
            // One thread per screen: the gold belongs to the primary action.
        }
        .task {
            await model.load()
            await model.markViewed()
        }
        .task {
            for await _ in NotificationCenter.default.notifications(named: ModelContext.didSave) {
                await model.load()
            }
        }
    }

    private func header(_ seam: SeamSummary) -> some View {
        let covers = SeamPresentation.covers(seam, size: 120)
        return VStack(spacing: Space.s3) {
            SeamLine(leading: covers.0, trailing: covers.1, direction: SeamPresentation.direction(seam.direction),
                     isMonitoring: seam.isMonitored && !seam.isPaused, knot: seam.isPaused ? .paused : .direction, style: .hero)
            VStack(spacing: Space.s1) {
                Text(seam.name).font(.antiphonTitle1).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                Text(SeamDetailModel.headerDetail(for: seam))
                    .font(.footnote).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func actions(_ seam: SeamSummary) -> some View {
        GlassEffectContainer(spacing: Space.s2) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.s2) { primary(seam); rules }
                VStack(spacing: Space.s2) { primary(seam); rules }
            }
        }
    }

    /// One prominent action: review when something waits, otherwise sync.
    @ViewBuilder
    private func primary(_ seam: SeamSummary) -> some View {
        if seam.counts.review > 0 {
            Button("Review \(PlanCopy.count(seam.counts.review, "track"))", systemImage: "questionmark.circle.fill") {
                model.filter = .toReview
            }
            .buttonSizing(.flexible)
            .glassButton(.primary)
        } else {
            Button("Sync now", systemImage: "arrow.triangle.2.circlepath") { onSyncNow(seam.id) }
                .buttonSizing(.flexible)
                .glassButton(.primary)
        }
    }

    private var rules: some View {
        Button("Rules") { path.append(.rules(model.seamId)) }.glassButton(.secondary)
    }

    /// The cover's colors bleed under the toolbar and fade into the ground.
    private var heroBackground: some View {
        CoverPlaceholder(seed: model.detail?.summary.name ?? "")
            .frame(height: 420)
            .backgroundExtensionEffect()
            .opacity(heroOpacity)
            .mask(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
    }
}
