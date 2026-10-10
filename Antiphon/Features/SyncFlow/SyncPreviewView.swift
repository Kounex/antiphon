import AntiphonDesign
import SwiftUI

/// A dry run before any write. The headline says the worst case in plain
/// words; close matches don't sync until approved, so the button counts
/// only what happens now.
struct SyncPreviewView: View {
    let model: SyncFlowModel
    let onDone: () -> Void

    @Environment(SyncCoordinator.self) private var coordinator
    @State private var showsEveryTrack = false

    var body: some View {
        Group {
            switch model.phase {
            case .planning(let checked, let total):
                planning(checked: checked, total: total)
            case .failed(let message):
                failed(message)
            default:
                preview
            }
        }
        .background(Color.canvas)
        .navigationTitle("Preview")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func planning(checked: Int, total: Int) -> some View {
        VStack(spacing: Space.s4) {
            ProgressView()
            Text(total > 0 ? "Checking \(checked) of \(total) tracks" : "Reading both playlists")
                .font(.callout).foregroundStyle(Color.inkMuted)
                .monospacedDigit()
            Text("Nothing changes until you approve the preview.")
                .font(.footnote).foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func failed(_ message: String) -> some View {
        VStack(spacing: Space.s4) {
            Banner(tone: .failed, symbol: "exclamationmark.triangle.fill", title: "Couldn't make a preview", message: message)
            Button("Try again", systemImage: "arrow.clockwise") { Task { await model.plan() } }.glassButton(.secondary)
        }
        .padding(Space.s4)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var preview: some View {
        List {
            if let notice = model.replannedNotice {
                Banner(tone: .thread, symbol: "info.circle", title: "Updated preview", message: notice).plainRow()
            }
            Text(model.headline)
                .font(.antiphonTitle2).foregroundStyle(Color.ink)
                .plainRow()
            ForEach(model.sides, id: \.platform) { side in
                SideCard(side: side, playlistName: model.playlistName(on: side.platform), seed: model.seam?.name ?? "")
                    .plainRow(vertical: Space.s2)
            }
            if let conflicts = model.planned?.plan.conflicts, !conflicts.isEmpty {
                Banner(tone: .review, symbol: "questionmark.circle.fill",
                       title: "\(PlanCopy.count(conflicts.count, "removal")) to decide",
                       message: "Nothing is removed until you choose what happens to \(conflicts.count == 1 ? "it" : "them").")
                .plainRow()
            }
            Section {
                Button { showsEveryTrack = true } label: {
                    HStack { Text("See every track").foregroundStyle(Color.ink); Spacer(); Image(systemName: "chevron.right").foregroundStyle(Color.inkFaint) }
                }
                HStack {
                    Text("Put new tracks").foregroundStyle(Color.ink)
                    Spacer()
                    Text("At the end").foregroundStyle(Color.inkMuted)
                }
                .accessibilityElement(children: .combine)
            }
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button(model.primaryTitle, systemImage: model.writeCount > 0 ? "arrow.triangle.2.circlepath" : "checkmark") {
                if model.writeCount > 0 { model.start(using: coordinator) } else { onDone() }
            }
            .buttonSizing(.flexible)
            .glassButton(.primary)
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s2)
        }
        .sheet(isPresented: $showsEveryTrack) { EveryTrackSheet(model: model) }
    }
}

/// One side of the preview: "+33 to Gym Rotation" and how those break down.
private struct SideCard: View {
    let side: SyncPlan.Side
    let playlistName: String
    let seed: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            let header = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
                : AnyLayout(HStackLayout(spacing: Space.s3))
            header {
                if !dynamicTypeSize.isAccessibilitySize {
                    CoverArt(seed: seed, size: 48, service: SeamPresentation.service(side.platform))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlistName).font(.headline).foregroundStyle(Color.ink)
                    Text(side.platform.rawValue).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                if side.missingCount > 0 {
                    Text("+\(side.missingCount)").font(.metric).foregroundStyle(Color.thread)
                        .lineLimit(1).fixedSize()
                        .accessibilityLabel("\(side.missingCount) tracks missing here")
                }
            }
            HealthBar(health: SeamHealth(synced: side.automaticAdds.count, review: side.reviewAdds.count,
                                         missing: side.unavailable.count, total: side.missingCount))
            VStack(alignment: .leading, spacing: Space.s1) {
                if side.reviewAdds.isEmpty && side.unavailable.isEmpty && !side.automaticAdds.isEmpty {
                    Text("All \(side.automaticAdds.count) are exact matches.").font(.footnote).foregroundStyle(Color.inkMuted)
                } else {
                    line("checkmark.circle.fill", .statusSynced, "Exact matches, added now", side.automaticAdds.count)
                    line("questionmark.circle.fill", .statusReview, "Close matches, waiting for you", side.reviewAdds.count)
                    line("circle.slash", .statusMissing, "Not on \(side.platform.rawValue)", side.unavailable.count)
                }
                let removals = side.removals.filter { !$0.isGuided }.count
                let guided = side.removals.filter(\.isGuided).count
                if removals > 0 { line("minus.circle.fill", .statusFailed, "Removed from \(playlistName)", removals) }
                if guided > 0 {
                    Text("Remove \(PlanCopy.count(guided, "track")) in the Music app yourself. Antiphon can't remove tracks from playlists it didn't create.")
                        .font(.footnote).foregroundStyle(Color.inkMuted)
                }
            }
        }
        .padding(Space.s4)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
    }

    @ViewBuilder
    private func line(_ symbol: String, _ color: Color, _ text: String, _ count: Int) -> some View {
        if count > 0 {
            HStack {
                Image(systemName: symbol).foregroundStyle(color).symbolRenderingMode(.hierarchical).accessibilityHidden(true)
                Text(text).font(.footnote).foregroundStyle(Color.ink)
                Spacer()
                Text("\(count)").font(.metricSmall).foregroundStyle(Color.ink)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Every planned track, grouped by what happens to it.
private struct EveryTrackSheet: View {
    let model: SyncFlowModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(model.sides, id: \.platform) { side in
                    section("Added to \(model.playlistName(on: side.platform))", side.automaticAdds.map { ($0.source, "\($0.match.confidence)% · \(SeamPresentation.reasonPhrase($0.match.reason))") }, state: .synced)
                    section("Waiting for you", side.reviewAdds.map { ($0.source, "\($0.match.confidence)% match, \(SeamPresentation.reasonPhrase($0.match.reason))") }, state: .review(confidence: 0))
                    section("Not on \(side.platform.rawValue)", side.unavailable.map { ($0.source, $0.source.artist) }, state: .missing)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Every track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func section(_ title: String, _ items: [(CatalogTrack, String)], state: AntiphonDesign.TrackRow.State) -> some View {
        if !items.isEmpty {
            Section(title) {
                ForEach(items, id: \.0.id) { track, detail in
                    AntiphonDesign.TrackRow(title: track.title, detail: "\(track.artist) · \(detail)",
                                            artwork: CoverArt(url: track.artworkURL.flatMap(URL.init(string:)), seed: track.title, size: 40),
                                            state: state)
                    .listRowBackground(Color.canvasRaised)
                }
            }
        }
    }
}
