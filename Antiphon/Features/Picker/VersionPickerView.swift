import AntiphonDesign
import SwiftUI

/// "Choose the version": every version of one song on the other side, with
/// the seam it's for at the top. What "Use this version" does depends on
/// where it opened, so the caller passes it in.
struct VersionPickerView: View {
    @State var model: VersionPickerModel
    /// Uses the version; returns the removals the person has to make themselves.
    let onUse: (MatchCandidate) async throws -> [SyncOperation]
    /// Review: the song is skipped instead.
    var onSkip: (() -> Void)? = nil
    /// "Let Antiphon choose again", for a song with a pick.
    var onForget: (() async throws -> Void)? = nil
    let onClose: () -> Void

    @State private var player = AudioPreviewPlayer()
    @State private var isWorking = false
    @State private var guided: [SyncOperation] = []
    @State private var failure: String?

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            List {
                seamHeader.plainRow()
                songCard.plainRow()
                if !guided.isEmpty {
                    Banner(tone: .review, symbol: "hand.raised.fill", title: "One thing to do in the Music app",
                           message: PickCopy.guided(guided, in: model.target))
                    .plainRow()
                }
                Section {
                    HStack(spacing: Space.s2) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color.inkMuted)
                        TextField("Search \(model.target.target.rawValue)", text: $model.query)
                            .submitLabel(.search)
                            .onSubmit { Task { await model.runSearch() } }
                        if model.isSearching { ProgressView() }
                    }
                    ForEach(model.versions, id: \.track.id) { version in
                        row(version)
                    }
                    if model.searchFailed {
                        Text("\(model.target.target.rawValue) didn't answer. Check your connection and search again.")
                            .font(.footnote).foregroundStyle(Color.statusFailed)
                    }
                } header: {
                    Text("Versions on \(model.target.target.rawValue)").font(.antiphonTitle3).foregroundStyle(Color.ink).textCase(nil)
                }
                .listRowBackground(Color.canvasRaised)
                if let selected = model.selected, !model.isCurrent(selected) || model.target.currentTrack == nil {
                    Section("Compared with the song") {
                        ForEach(model.comparison, id: \.label) { row in
                            HStack(alignment: .firstTextBaseline) {
                                Text(row.label).font(.footnote).foregroundStyle(Color.inkMuted).frame(width: 64, alignment: .leading)
                                Text(row.left).font(row.isCode ? .code : .subheadline).foregroundStyle(Color.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text(row.right).font(row.isCode ? .code : .subheadline)
                                    .foregroundStyle(row.differs ? Color.statusReview : Color.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .accessibilityElement(children: .combine)
                            .accessibilityValue(row.differs ? "Differs" : "")
                        }
                    }
                    .listRowBackground(Color.canvasRaised)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .frame(maxWidth: 700)
            .frame(maxWidth: .infinity)
            .background(Color.canvas)
            .navigationTitle("Choose the version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onClose).tint(.ink)
                }
            }
            .safeAreaInset(edge: .bottom) { buttons.frame(maxWidth: 700).padding(.horizontal, Space.s4).padding(.bottom, Space.s2) }
            .task { await model.load() }
            .onDisappear { player.stop() }
        }
        .tint(.thread)
    }

    // MARK: - Pieces

    /// Which seam this is for, and where the version goes.
    private var seamHeader: some View {
        let seam = model.target.seam
        let covers = SeamPresentation.covers(seam, size: 36)
        return HStack(spacing: Space.s3) {
            SeamLine(leading: covers.0, trailing: covers.1, direction: SeamPresentation.direction(seam.direction),
                     isMonitoring: seam.isMonitored && !seam.isPaused, style: .compact)
                .frame(width: 104)
            VStack(alignment: .leading, spacing: 2) {
                Text(PickCopy.seamTitle(model.target)).font(.headline).foregroundStyle(Color.ink)
                Text(PickCopy.seamDetail(model.target)).font(.footnote).foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var songCard: some View {
        let source = model.target.source
        return VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                CoverArt(url: source.artworkURL.flatMap(URL.init(string:)), seed: source.title, size: 56,
                         service: SeamPresentation.service(source.platform))
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.title).font(.headline).foregroundStyle(Color.ink)
                    Text(source.artist).font(.subheadline).foregroundStyle(Color.inkMuted)
                    Text(PickCopy.versionDetail(source)).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                Spacer(minLength: 0)
            }
            Label(PickCopy.status(model.target), systemImage: model.target.isPicked ? "pin.fill" : "music.note")
                .font(.footnote).foregroundStyle(model.target.isPicked ? Color.thread : Color.inkMuted)
        }
        .padding(Space.s4)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
        .accessibilityElement(children: .combine)
    }

    private func row(_ version: MatchCandidate) -> some View {
        let isSelected = model.selected?.track.id == version.track.id
        return Button { model.selected = version } label: {
            HStack(spacing: Space.s3) {
                CoverArt(url: version.track.artworkURL.flatMap(URL.init(string:)), seed: version.track.title, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(version.track.title).font(.headline).foregroundStyle(Color.ink)
                    Text(PickCopy.versionDetail(version.track)).font(.footnote).foregroundStyle(Color.inkMuted)
                    if model.isCurrent(version) {
                        Text("In the playlist").font(.caption.weight(.semibold)).foregroundStyle(Color.thread)
                    }
                }
                Spacer(minLength: Space.s2)
                if let url = version.track.previewURL.flatMap(URL.init(string:)) {
                    Button(player.playingURL == url ? "Stop preview" : "Play preview",
                           systemImage: player.playingURL == url ? "stop.fill" : "play.fill") { player.toggle(url) }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                        .foregroundStyle(Color.thread)
                }
                Text("\(version.confidence)%").font(.metricSmall)
                    .foregroundStyle(ConfidenceMeter.band(version.confidence).color)
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isSelected ? Color.thread : Color.inkFaint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var buttons: some View {
        VStack(spacing: Space.s2) {
            if let failure {
                Text(failure).font(.footnote).foregroundStyle(Color.statusFailed).multilineTextAlignment(.center)
            }
            GlassEffectContainer(spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    if !guided.isEmpty {
                        Button("Done", action: onClose).buttonSizing(.flexible).glassButton(.primary)
                    } else {
                        if let onSkip {
                            Button("Skip track", action: onSkip).buttonSizing(.flexible).glassButton(.secondary)
                        } else if model.target.isPicked, let onForget {
                            Button("Let Antiphon choose") { forget(onForget) }
                                .buttonSizing(.flexible).glassButton(.secondary).disabled(isWorking)
                        }
                        Button(isWorking ? "Saving…" : "Use this version") { use() }
                            .buttonSizing(.flexible).glassButton(.primary)
                            .disabled(!model.canUse || isWorking)
                    }
                }
            }
        }
    }

    private func forget(_ onForget: @escaping () async throws -> Void) {
        isWorking = true
        Task {
            defer { isWorking = false }
            do { try await onForget(); onClose() }
            catch { failure = "Antiphon couldn't forget the pick. Try again." }
        }
    }

    private func use() {
        guard let selected = model.selected else { return }
        isWorking = true
        failure = nil
        Task {
            defer { isWorking = false }
            do {
                let toDo = try await onUse(selected)
                if toDo.isEmpty { onClose() } else { guided = toDo }
            } catch {
                failure = "Antiphon couldn't change the playlist. Nothing was lost; try again."
            }
        }
    }
}

extension PickCopy {
    /// "Delete the old Word Up! from Remixes in the Music app. Apple doesn't let
    /// apps remove songs from playlists you made."
    static func guided(_ operations: [SyncOperation], in target: PickTarget) -> String {
        let titles = operations.map(\.track.title).formatted(.list(type: .and))
        return "Your pick is in. Delete the old \(titles) from \(target.seam.side(target.target).name) in the Music app: "
            + "Apple doesn't let apps remove songs from playlists you made."
    }
}
