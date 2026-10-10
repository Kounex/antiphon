import AntiphonDesign
import SwiftUI

/// Two-way seams never delete on their own. A removal on one side becomes a
/// question with three outcomes; the button repeats the choice as a verb.
struct ConflictSheet: View {
    @State var model: ConflictModel
    let onDone: () -> Void

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(spacing: Space.s4) {
                let item = model.item
                SeamLine(
                    leading: CoverArt(seed: item.seamName, size: 64, service: .spotify),
                    trailing: CoverArt(seed: item.seamName, size: 64, service: .appleMusic),
                    direction: .twoWay, isMonitoring: true, knot: .problem, style: .card
                )
                .padding(.horizontal, Space.s8)
                VStack(spacing: Space.s2) {
                    Text(model.title).font(.antiphonTitle2).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                    Text(model.subtitle()).font(.subheadline).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
                }
                AntiphonDesign.TrackRow(
                    title: item.conflict.track.title,
                    detail: [item.conflict.track.artist, item.conflict.track.album].compactMap { $0 }.joined(separator: " · "),
                    artwork: CoverArt(url: item.conflict.track.artworkURL.flatMap(URL.init(string:)), seed: item.conflict.track.title, size: 40),
                    state: .removed
                )
                .padding(Space.s3)
                .background(Color.canvasRaised.opacity(0.7), in: .rect(cornerRadius: Radius.row))
                VStack(spacing: Space.s2) {
                    choice(.removeOnOtherSide, "Remove it from \(item.conflict.removedFrom.other.rawValue) too", "Both playlists match again.")
                    choice(.restore, "Put it back on \(item.conflict.removedFrom.rawValue)", "Undo the removal.")
                    choice(.keepDifference, "Keep the difference", "Antiphon ignores this track in this seam.")
                }
                if let note = model.guidedNote {
                    Text(note).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                if let text = model.sameForOthersText {
                    Toggle(text, isOn: $model.applyToOthers).tint(.thread).font(.subheadline)
                }
                if let error = model.error {
                    Text(error).font(.footnote).foregroundStyle(Color.statusFailed)
                }
                Button(model.buttonTitle) { Task { await model.confirm(); if model.isDone { onDone() } } }
                    .buttonSizing(.flexible)
                    .glassButton(.primary)
                    .disabled(model.isWorking)
            }
            .padding(Space.s5)
        }
        .presentationDetents([.large])
    }

    private func choice(_ outcome: ConflictOutcome, _ title: String, _ detail: String) -> some View {
        let on = model.outcome == outcome
        return Button { withAnimation(.smooth) { model.outcome = outcome } } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(on ? Color.thread : Color.inkFaint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Color.ink)
                    Text(detail).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
            .background(on ? Color.threadSoft : Color.canvasRaised, in: .rect(cornerRadius: Radius.row))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}
