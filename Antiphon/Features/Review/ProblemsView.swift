import AntiphonDesign
import SwiftUI

/// What broke, what it affects, and the one action that fixes it.
struct ProblemsView: View {
    @State var model: ProblemsModel
    let onSignIn: () -> Void
    let onOpenSeam: (UUID) -> Void
    @State private var showsAllPaused = false

    var body: some View {
        List {
            if let card = model.signedOut {
                VStack(alignment: .leading, spacing: Space.s4) {
                    HStack(alignment: .top, spacing: Space.s3) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.statusFailed).font(.title3)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(card.title).font(.headline).foregroundStyle(Color.ink)
                            Text(card.message).font(.footnote).foregroundStyle(Color.inkMuted)
                        }
                    }
                    SignInCapsule(service: .spotify, title: "Sign in to Spotify", action: onSignIn)
                }
                .padding(Space.s4)
                .background(Color.statusFailedSoft, in: .rect(cornerRadius: Radius.card))
                .plainRow()

                if !model.pausedSeams.isEmpty {
                    Section("Paused because of this") {
                        ForEach(showsAllPaused ? model.pausedSeams : Array(model.pausedSeams.prefix(3))) { seam in
                            HStack(spacing: Space.s3) {
                                CoverArt(url: seam.spotify.artworkURL, seed: seam.name, size: 40)
                                Text(seam.name).font(.headline).foregroundStyle(Color.ink)
                                Spacer()
                                StatusPill(.paused)
                            }
                        }
                        if model.pausedSeams.count > 3 && !showsAllPaused {
                            Button("Show \(model.pausedSeams.count - 3) more") { showsAllPaused = true }.foregroundStyle(Color.thread)
                        }
                    }
                    .listRowBackground(Color.canvasRaised)
                }
            }

            if !model.others.isEmpty {
                Section(model.signedOut == nil ? "" : "Other") {
                    ForEach(model.others) { row in
                        HStack(spacing: Space.s3) {
                            Image(systemName: symbol(row.kind)).foregroundStyle(row.kind == .rateLimited ? Color.inkMuted : Color.statusFailed)
                                .frame(width: 28).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.title).font(.body).foregroundStyle(Color.ink)
                                Text(row.detail).font(.footnote).foregroundStyle(Color.inkMuted)
                            }
                            Spacer()
                            if let seamId = row.seamId, row.kind != .rateLimited {
                                Button("Fix") { onOpenSeam(seamId) }.glassButton(.secondary).controlSize(.small)
                            }
                        }
                    }
                }
                .listRowBackground(Color.canvasRaised)
            }

            if model.count == 0 {
                ContentUnavailableView("Nothing needs fixing", systemImage: "checkmark.circle",
                                       description: Text("If something breaks, it shows up here with what it affects."))
                    .plainRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Problems")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private func symbol(_ kind: ProblemKind) -> String {
        switch kind {
        case .playlistDeleted: "trash"
        case .rateLimited: "clock"
        case .signedOut: "person.crop.circle.badge.exclamationmark"
        case .writeRefused, .subscriptionLapsed: "exclamationmark.triangle"
        }
    }
}
