import AntiphonDesign
import SwiftUI

/// The live sync, as a partial-height glass sheet. Rows land as the count
/// rises; the person can pause or hide it and the accessory keeps going.
struct SyncingView: View {
    let model: SyncFlowModel
    let onHide: () -> Void

    /// Not expanded: tall enough for the progress, a few rows, the buttons
    /// and the note (half height left room for one row, or none).
    static let collapsed: PresentationDetent = .fraction(0.62)

    @Environment(SyncCoordinator.self) private var coordinator
    /// The room left for rows, and one row's height: how many fit.
    @State private var rowsHeight: CGFloat = 0
    @State private var rowHeight: CGFloat = 56

    var body: some View {
        let progress = coordinator.syncProgress[model.seamId]
        let done = progress.map { $0.completedTracks + $0.failedTracks } ?? 0
        let total = max(progress?.totalTracks ?? 0, 1)
        let seam = model.seam

        // No scrolling: the buttons and the note always show, and the rows
        // take whatever height is left, more of them when the sheet expands.
        VStack(spacing: Space.s4) {
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
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
                .overlay(alignment: .top) { landingRows(done: done) }
                .clipped()
            VStack(spacing: Space.s3) {
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Space.s4)
    }

    /// The rows around the track being added: two already added (or half
    /// of what fits), the current one, then the ones waiting.
    static func window(done: Int, count: Int, fits: Int) -> Range<Int> {
        let start = max(0, min(done - fits / 2, count - fits))
        return start..<max(start, min(start + fits, count))
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

    /// As many rows as fit around the current position: added, adding, waiting.
    private func landingRows(done: Int) -> some View {
        let writes = model.plannedWrites
        let fits = rowHeight > 0 ? Int(rowsHeight / rowHeight) : 0
        let range = Self.window(done: done, count: writes.count, fits: fits)
        return VStack(spacing: 0) {
            ForEach(range, id: \.self) { index in
                let add = writes[index]
                AntiphonDesign.TrackRow(
                    title: add.source.title, detail: add.source.artist,
                    artwork: CoverArt(url: SeamPresentation.cover(of: add.source, writing: add.match.track),
                                      seed: add.source.title, size: 40),
                    state: index < done ? .synced : (index == done ? .syncing : .pending)
                )
                .padding(.horizontal, Space.s3)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { if $0 > 0 { rowHeight = $0 } }
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: done)
        .background(Color.canvasRaised.opacity(0.6), in: .rect(cornerRadius: Radius.row))
    }
}
