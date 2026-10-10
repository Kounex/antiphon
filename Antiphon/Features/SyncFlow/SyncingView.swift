import AntiphonDesign
import SwiftUI

/// The live sync, as a partial-height glass sheet. Rows land as the count
/// rises; the person can pause or hide it and the accessory keeps going.
struct SyncingView: View {
    let model: SyncFlowModel
    let onHide: () -> Void

    @Environment(SyncCoordinator.self) private var coordinator

    var body: some View {
        let progress = coordinator.syncProgress[model.seamId]
        let done = progress.map { $0.completedTracks + $0.failedTracks } ?? 0
        let total = max(progress?.totalTracks ?? 0, 1)
        let seam = model.seam

        ScrollView {
            VStack(spacing: Space.s5) {
                if let seam {
                    let covers = SeamPresentation.covers(seam, size: 72)
                    SeamLine(leading: covers.0, trailing: covers.1, direction: SeamPresentation.direction(seam.direction),
                             isMonitoring: true, style: .hero)
                        .padding(.horizontal, Space.s6)
                }
                VStack(spacing: Space.s1) {
                    HStack(alignment: .firstTextBaseline, spacing: Space.s1 + 2) {
                        Text("\(done)").metricXL().foregroundStyle(Color.ink).lineLimit(1).minimumScaleFactor(0.5)
                        Text("/ \(total)").font(.metric).foregroundStyle(Color.inkMuted)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(done) of \(total) tracks")
                    Text(statusLine(progress, done: done, total: total))
                        .font(.footnote).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                }
                ProgressView(value: Double(done), total: Double(total))
                    .tint(.thread)
                    .accessibilityHidden(true)
                landingRows(done: done)
                GlassEffectContainer(spacing: Space.s2) {
                    HStack(spacing: Space.s2) {
                        Button("Pause") { coordinator.cancelSync(pairId: model.seamId) }
                            .buttonSizing(.flexible).glassButton(.secondary)
                        Button("Hide", action: onHide)
                            .buttonSizing(.flexible).glassButton(.secondary)
                    }
                }
                Text("You can leave. Progress stays above the tab bar.")
                    .font(.footnote).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
            }
            .padding(Space.s4)
        }
    }

    private func statusLine(_ progress: SyncProgress?, done: Int, total: Int) -> String {
        var parts: [String] = []
        if case .adding(let platform) = progress?.phase {
            parts.append("Adding to \(model.playlistName(on: platform == "Spotify" ? .spotify : .appleMusic))")
        } else {
            parts.append("Matching tracks")
        }
        if let started = model.startedAt, let eta = SyncETA.text(done: done, total: total, elapsed: Date().timeIntervalSince(started)) {
            parts.append(eta)
        }
        return parts.joined(separator: " · ")
    }

    /// The four rows around the current position: added, adding, waiting.
    private func landingRows(done: Int) -> some View {
        let writes = model.plannedWrites
        let start = max(0, min(done - 2, writes.count - 4))
        let visible = Array(writes.dropFirst(start).prefix(4).enumerated())
        return VStack(spacing: 0) {
            ForEach(visible, id: \.element.source.id) { offset, add in
                let index = start + offset
                AntiphonDesign.TrackRow(
                    title: add.source.title, detail: add.source.artist,
                    artwork: CoverArt(url: add.source.artworkURL.flatMap(URL.init(string:)), seed: add.source.title, size: 40),
                    state: index < done ? .synced : (index == done ? .syncing : .pending)
                )
                .padding(.horizontal, Space.s3)
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: done)
        .background(Color.canvasRaised.opacity(0.6), in: .rect(cornerRadius: Radius.row))
    }
}
