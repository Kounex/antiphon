import AntiphonDesign
import SwiftUI

/// Close matches as a card stack: swipe right to add, left to skip, or pick
/// another version. Previews play so ears can decide. Two-way removals
/// waiting for an answer follow as cards of their own.
struct ReviewQueueView: View {
    @State var model: ReviewQueueModel
    let makeDetail: (ReviewItem) -> MatchDetailModel
    let onClose: () -> Void

    @State private var player = AudioPreviewPlayer()
    @State private var drag: CGSize = .zero
    @State private var detailItem: ReviewItem?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            ZStack {
                background
                if model.isFinished {
                    finished
                } else if let entry = model.currentEntry {
                    VStack(spacing: Space.s4) {
                        ProgressView(value: model.progress).tint(.thread).accessibilityHidden(true)
                        stack(entry)
                        if let error = model.error {
                            Text(error).font(.footnote).foregroundStyle(Color.statusFailed).multilineTextAlignment(.center)
                        }
                        if case .match(let item) = entry { controls(item) }
                    }
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s4)
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(model.isFinished ? "" : model.positionText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onClose).tint(.ink)
                }
                if !model.isFinished {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Later", action: onClose).tint(.ink)
                    }
                }
            }
            .navigationDestination(item: $detailItem) { item in
                MatchDetailView(model: makeDetail(item)) { candidate in
                    detailItem = nil
                    Task {
                        if let candidate { await model.accept(candidate) } else { await model.skip() }
                    }
                }
            }
        }
        .task { if !model.isLoaded { await model.load() } }
        .onDisappear { player.stop() }
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            Color.canvas
            CoverPlaceholder(seed: backgroundSeed)
                .opacity(0.5)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var backgroundSeed: String {
        switch model.currentEntry {
        case .match(let item): item.source.title
        case .conflict(let item): item.conflict.track.title
        case nil: ""
        }
    }

    private func stack(_ entry: ReviewQueueModel.Entry) -> some View {
        ZStack {
            ForEach(0..<min(2, model.upcomingCount), id: \.self) { depth in
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(Color.canvasRaised)
                    .opacity(depth == 0 ? 0.6 : 0.35)
                    .scaleEffect(x: depth == 0 ? 0.95 : 0.9, y: 1, anchor: .top)
                    .offset(y: depth == 0 ? -12 : -24)
                    .accessibilityHidden(true)
            }
            switch entry {
            case .match(let item):
                ReviewCard(item: item, player: player)
                    .offset(x: drag.width)
                    .rotationEffect(.degrees(reduceMotion ? 0 : Double(drag.width) / 25))
                    .gesture(swipe)
                    .accessibilityElement(children: .contain)
                    .accessibilityAction(named: "Same track, add it") { Task { await model.accept() } }
                    .accessibilityAction(named: "Skip this track") { Task { await model.skip() } }
                    .accessibilityAction(named: "Pick another version") { detailItem = item }
            case .conflict(let item):
                RemovalCard(item: item) { outcome in Task { await model.resolve(item, as: outcome) } }
            }
        }
        .id(entry.id)
    }

    private var swipe: some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let width = value.translation.width
                if width > 120 {
                    withAnimation(.smooth) { drag = CGSize(width: 600, height: 0) }
                    Task { await model.accept(); drag = .zero }
                } else if width < -120 {
                    withAnimation(.smooth) { drag = CGSize(width: -600, height: 0) }
                    Task { await model.skip(); drag = .zero }
                } else {
                    withAnimation(.smooth) { drag = .zero }
                }
            }
    }

    private func controls(_ item: ReviewItem) -> some View {
        GlassEffectContainer(spacing: Space.s6) {
            HStack(spacing: Space.s6) {
                roundButton("xmark", label: "Skip this track", tint: .statusFailed, prominent: false) { Task { await model.skip() } }
                roundButton("list.bullet", label: "Pick another version", tint: .ink, prominent: false) { detailItem = item }
                roundButton("checkmark", label: "Same track, add it", tint: .onThread, prominent: true) { Task { await model.accept() } }
            }
        }
    }

    private func roundButton(_ symbol: String, label: String, tint: Color, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title2.weight(.bold))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(prominent ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
        .buttonBorderShape(.circle)
        .controlSize(.extraLarge)
        .tint(prominent ? .thread : nil)
        .foregroundStyle(tint)
        .accessibilityLabel(label)
    }

    private var finished: some View {
        VStack(spacing: Space.s4) {
            Image(systemName: "checkmark")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(Color.statusSynced)
                .frame(width: 80, height: 80)
                .glassEffect(.regular, in: .circle)
                .accessibilityHidden(true)
            Text("All caught up").font(.antiphonTitle2).foregroundStyle(Color.ink)
            Text(model.summary).font(.body).foregroundStyle(Color.inkMuted)
            if !model.guidedLeft.isEmpty {
                Text("Still to do in the Music app: remove \(model.guidedLeft.map(\.track.title).formatted(.list(type: .and))).")
                    .font(.footnote).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
            }
            Button("Done", action: onClose).glassButton(.primary)
        }
        .padding(Space.s6)
    }
}

/// Wraps the two glass styles so one call site can switch between them.
struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

/// "Is this the same track?": both versions side by side with the evidence.
struct ReviewCard: View {
    let item: ReviewItem
    let player: AudioPreviewPlayer
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.openURL) private var openURL

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(item.seamName.uppercased())
                    .font(.footnote).foregroundStyle(Color.inkMuted)
                Text("Is this the same track?").font(.antiphonTitle2).foregroundStyle(Color.ink)
                let columns = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s4))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: Space.s3))
                columns {
                    side(item.source)
                    if let best = item.best { side(best.track) }
                }
                if let best = item.best {
                    ConfidenceMeter(confidence: best.confidence, reason: ReviewCopy.explanation(item))
                }
                previews
            }
            .padding(Space.s5)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
    }

    private func side(_ track: CatalogTrack) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            CoverArt(url: track.artworkURL.flatMap(URL.init(string:)), seed: track.title, size: 140, cornerRadius: 16,
                     service: SeamPresentation.service(track.platform))
            Text(track.title).font(.headline).foregroundStyle(Color.ink)
            Text([track.artist, track.releaseYear.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(Color.inkMuted)
            Text(MatchComparison.length(track.durationMs)).font(.metricSmall).foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("On \(track.platform.rawValue): \(track.title), \(track.artist), \(MatchComparison.length(track.durationMs))")
    }

    @ViewBuilder
    private var previews: some View {
        let tracks = [item.source] + (item.best.map { [$0.track] } ?? [])
        let playable = tracks.compactMap { $0.previewURL.flatMap(URL.init(string:)) }
        HStack(spacing: Space.s2) {
            ForEach(playable, id: \.self) { url in
                Button(player.playingURL == url ? "Stop preview" : "Play Apple Music preview",
                       systemImage: player.playingURL == url ? "stop.fill" : "play.fill") { player.toggle(url) }
                    .glassButton(.secondary)
                    .controlSize(.small)
            }
            if let spotify = tracks.first(where: { $0.platform == .spotify })?.webURL {
                Button("Open in Spotify", systemImage: "arrow.up.right") { openURL(spotify) }
                    .glassButton(.secondary)
                    .controlSize(.small)
            }
        }
    }
}

/// "Holocene was removed on Apple Music": the three outcomes as verbs, one
/// tap each, same as the conflict sheet.
struct RemovalCard: View {
    let item: ConflictItem
    let onChoose: (ConflictOutcome) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(item.seamName.uppercased())
                    .font(.footnote).foregroundStyle(Color.inkMuted)
                Text(item.question).font(.antiphonTitle2).foregroundStyle(Color.ink)
                Text(item.noticedLine()).font(.subheadline).foregroundStyle(Color.inkMuted)
                AntiphonDesign.TrackRow(
                    title: item.conflict.track.title,
                    detail: [item.conflict.track.artist, item.conflict.track.album].compactMap { $0 }.joined(separator: " · "),
                    artwork: CoverArt(url: item.conflict.track.artworkURL.flatMap(URL.init(string:)), seed: item.conflict.track.title, size: 40),
                    state: .removed
                )
                VStack(spacing: Space.s2) {
                    ForEach([ConflictOutcome.removeOnOtherSide, .restore, .keepDifference], id: \.self) { outcome in
                        Button(ConflictResolver.buttonTitle(for: item.conflict, outcome: outcome)) { onChoose(outcome) }
                            .buttonSizing(.flexible)
                            .glassButton(.secondary)
                    }
                }
                if let note = item.guidedRemovalNote {
                    Text(note).font(.footnote).foregroundStyle(Color.inkMuted)
                }
            }
            .padding(Space.s5)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
        .shadow(color: .black.opacity(0.25), radius: 20, y: 12)
    }
}
