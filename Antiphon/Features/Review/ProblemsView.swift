import AntiphonDesign
import SwiftUI

/// What broke, what it affects, and the one action that fixes it.
struct ProblemsView: View {
    @State var model: ProblemsModel
    let onSignIn: () -> Void
    let onOpenSeam: (UUID) -> Void
    /// After "Recreate": the seam's first sync, as a preview.
    var onPreview: (UUID) -> Void = { _ in }
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
                        // The action sits under the words: beside them, a
                        // button that says what it does leaves no room for either.
                        VStack(alignment: .leading, spacing: Space.s3) {
                            HStack(alignment: .top, spacing: Space.s3) {
                                Image(systemName: symbol(row.kind)).foregroundStyle(row.kind == .rateLimited ? Color.inkMuted : Color.statusFailed)
                                    .frame(width: 28).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.title).font(.body).foregroundStyle(Color.ink)
                                    Text(row.detail).font(.footnote).foregroundStyle(Color.inkMuted)
                                }
                            }
                            if let seamId = row.seamId, let action = ProblemsModel.action(for: row) {
                                Button(action) {
                                    if row.recreateOn != nil {
                                        Task { if let seam = await model.recreate(row) { onPreview(seam) } }
                                    } else {
                                        onOpenSeam(seamId)
                                    }
                                }
                                .buttonSizing(.flexible)
                                .glassButton(.secondary).controlSize(.small)
                            }
                        }
                        .padding(.vertical, Space.s1)
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
        .task(id: StoreChanges.shared.revision) { await model.load() }
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
