import AntiphonDesign
import SwiftUI

enum NewSeamStep: Hashable {
    case twin, compare, rules, sync(UUID)
}

/// Start from either side. Picking several playlists queues them; each
/// gets its own twin, comparison, rules and previewed first sync.
struct NewSeamFlowView: View {
    @State var model: NewSeamModel
    let makeSyncFlow: (UUID) -> SyncFlowModel
    let onReview: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var path: [NewSeamStep] = []

    var body: some View {
        NavigationStack(path: $path) {
            PickPlaylistsStep(model: model, onClose: { dismiss() }) {
                model.startQueue()
                path = [.twin]
            }
            .navigationDestination(for: NewSeamStep.self) { step in
                switch step {
                case .twin:
                    TwinStep(model: model) {
                        if case .existing = model.twinChoice { path.append(.compare) } else { path.append(.rules) }
                    }
                case .compare:
                    CompareStep(model: model) { path.append(.rules) }
                case .rules:
                    HowToSyncStep(model: model) { id in path.append(.sync(id)) }
                case .sync(let id):
                    SyncFlowView(
                        model: makeSyncFlow(id),
                        nextName: model.queue?.next?.name,
                        onReview: { onReview($0); dismiss() },
                        onNext: { if model.advanceQueue() { path = [.twin] } else { dismiss() } },
                        onDone: { dismiss() }
                    )
                }
            }
        }
        .tint(.thread)
        #if DEBUG
        .task { let steps = await model.debugPrepare(); if !steps.isEmpty { path = steps } }
        #endif
    }
}

/// A full-width glass bar pinned to the bottom of a step.
struct StepBar<Leading: View>: View {
    let actionTitle: String
    let isEnabled: Bool
    let action: () -> Void
    @ViewBuilder let leading: () -> Leading
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility sizes the button alone says what happens next.
        let compact = dynamicTypeSize.isAccessibilitySize
        HStack(spacing: Space.s3) {
            if !compact { leading().frame(maxWidth: .infinity, alignment: .leading) }
            Button(actionTitle, action: action)
                .buttonSizing(compact ? .flexible : .fitted)
                .glassButton(.primary)
                .fixedSize(horizontal: !compact, vertical: false)
                .disabled(!isEnabled)
        }
        .padding(.leading, compact ? Space.s2 : Space.s5)
        .padding(Space.s2)
        .glassEffect(.regular, in: .capsule)
        .padding(.horizontal, Space.s4)
        .padding(.bottom, Space.s2)
    }
}

// MARK: - 1. Pick

struct PickPlaylistsStep: View {
    let model: NewSeamModel
    let onClose: () -> Void
    let onNext: () -> Void

    var body: some View {
        @Bindable var model = model
        List {
            Picker("Start from", selection: Binding(get: { model.side }, set: { model.switchSide(to: $0) })) {
                ForEach(Platform.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .plainRow()
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).plainRow()
            } else if let error = model.loadError {
                Banner(tone: .failed, symbol: "exclamationmark.triangle.fill", title: "Couldn't load playlists", message: error).plainRow()
            }
            Section {
                ForEach(model.visiblePlaylists) { playlist in
                    row(playlist)
                }
            }
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .searchable(text: $model.search, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search \(model.playlists[model.side]?.count ?? 0) playlists")
        .navigationTitle("New seam")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark", action: onClose).tint(.ink)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.selected.isEmpty {
                StepBar(actionTitle: "Next", isEnabled: true, action: onNext) {
                    Text("\(model.selected.count) selected").font(.headline).foregroundStyle(Color.ink)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth, value: model.selected.count)
        .task(id: model.side) { await model.loadPlaylists() }
    }

    private func row(_ playlist: LibraryPlaylist) -> some View {
        let reason = model.unavailableReason(for: playlist)
        let selected = model.isSelected(playlist)
        return Button { model.toggle(playlist) } label: {
            HStack(spacing: Space.s3) {
                CoverArt(url: playlist.artworkURL, seed: playlist.name, size: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text(playlist.name).font(.headline).foregroundStyle(Color.ink)
                    Text(reason ?? playlist.detail).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                Spacer(minLength: Space.s2)
                if reason == nil {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title2)
                        .foregroundStyle(selected ? Color.thread : Color.inkFaint)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(reason != nil)
        .opacity(reason == nil ? 1 : Opacity.missing)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(reason ?? "")
    }
}

// MARK: - 2. Twin

struct TwinStep: View {
    let model: NewSeamModel
    let onNext: () -> Void
    @State private var showsAll = false

    var body: some View {
        let source = model.source
        let other = source?.platform.other ?? .appleMusic
        List {
            if let source {
                HStack(spacing: Space.s4) {
                    CoverArt(url: source.artworkURL, seed: source.name, size: 72, service: SeamPresentation.service(source.platform))
                    VStack(alignment: .leading, spacing: Space.s1) {
                        Text(source.name).font(.antiphonTitle3).foregroundStyle(Color.ink)
                        Text(source.trackCount.map { "\($0) tracks on \(source.platform.rawValue)" } ?? source.platform.rawValue)
                            .font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                }
                .plainRow()
            }
            Section("Where should it go on \(other.rawValue)?") {
                choice(.linkExisting, title: "Link one I already have", detail: "Antiphon fills in what's missing.")
                if model.isRankingTwins {
                    HStack { ProgressView(); Text("Finding twins").font(.footnote).foregroundStyle(Color.inkMuted) }
                }
                ForEach(showsAll ? model.suggestions : Array(model.suggestions.prefix(3))) { suggestion in
                    suggestionRow(suggestion, total: source?.trackCount)
                }
                if model.suggestions.count > 3 && !showsAll {
                    Button("Browse all \(model.suggestions.count) playlists") { showsAll = true }.foregroundStyle(Color.thread)
                }
                choice(.createNew, title: "Create a new playlist",
                       detail: "Named “\(source?.name ?? "")”, with the same name and description.")
            }
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(model.queue.map { $0.sources.count > 1 ? $0.positionText : "Find its twin" } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            StepBar(actionTitle: isLinking ? "Compare" : "Choose direction", isEnabled: model.twinChoice != nil, action: onNext) {
                Text(isLinking ? "Linking \(model.targetName)" : "Creating \(model.targetName)")
                    .font(.footnote).foregroundStyle(Color.inkMuted).lineLimit(2)
            }
        }
        .task { if model.suggestions.isEmpty { await model.loadTwins() } }
    }

    private enum Kind { case linkExisting, createNew }

    private var isLinking: Bool {
        if case .existing = model.twinChoice { return true }
        return false
    }

    private func choice(_ kind: Kind, title: String, detail: String) -> some View {
        let on = kind == .createNew ? model.twinChoice == .createNew : isLinking
        return Button {
            if kind == .createNew { model.twinChoice = .createNew }
            else if let first = model.suggestions.first { model.twinChoice = .existing(first.playlist) }
        } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(on ? Color.thread : Color.inkFaint).font(.title3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).foregroundStyle(Color.ink)
                    Text(detail).font(.footnote).foregroundStyle(Color.inkMuted)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func suggestionRow(_ suggestion: TwinRanker.Suggestion, total: Int?) -> some View {
        let on = model.twinChoice == .existing(suggestion.playlist)
        return Button { model.twinChoice = .existing(suggestion.playlist) } label: {
            HStack(spacing: Space.s3) {
                CoverArt(url: suggestion.playlist.artworkURL, seed: suggestion.playlist.name, size: 48,
                         service: SeamPresentation.service(suggestion.playlist.platform))
                VStack(alignment: .leading, spacing: 2) {
                    Text(suggestion.playlist.name).font(.headline).foregroundStyle(Color.ink)
                    Text(sharedText(suggestion.shared, total: total)).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                Spacer()
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title2).foregroundStyle(on ? Color.thread : Color.inkFaint)
            }
        }
        .buttonStyle(.plain)
        .padding(.leading, Space.s6)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func sharedText(_ shared: Int?, total: Int?) -> String {
        guard let shared else { return "Not compared yet" }
        if let total { return "\(shared) of \(total) tracks already there" }
        return "\(PlanCopy.count(shared, "track")) already there"
    }
}

// MARK: - 3. Compare

struct CompareStep: View {
    let model: NewSeamModel
    let onNext: () -> Void

    var body: some View {
        @Bindable var model = model
        let overlap = model.overlap
        let source = model.source
        List {
            VennView(sourceOnly: overlap?.sourceOnly.count ?? 0, both: overlap?.both.count ?? 0,
                     targetOnly: overlap?.targetOnly.count ?? 0, sourcePlatform: source?.platform ?? .spotify)
                .accessibilityLabel(overlap?.accessibilityLabel(sourceName: source?.platform.rawValue ?? "",
                                                                 targetName: source?.platform.other.rawValue ?? "") ?? "")
                .plainRow()
            HStack {
                Label(source?.name ?? "", systemImage: "circle.fill").labelStyle(DotLabelStyle(platform: source?.platform ?? .spotify))
                Spacer()
                Label(model.targetName, systemImage: "circle.fill").labelStyle(DotLabelStyle(platform: source?.platform.other ?? .appleMusic))
            }
            .font(.footnote).foregroundStyle(Color.inkMuted)
            .plainRow()
            ChipBar([
                .init(NewSeamModel.Region.sourceOnly, "\(source?.platform.rawValue ?? "") only", count: overlap?.sourceOnly.count),
                .init(.targetOnly, "\(source?.platform.other.rawValue ?? "") only", count: overlap?.targetOnly.count),
                .init(.both, "Both", count: overlap?.both.count)
            ], selection: $model.region)
            .plainRow()
            Section {
                ForEach(model.regionTracks.prefix(200), id: \.id) { track in
                    AntiphonDesign.TrackRow(title: track.title, detail: [track.artist, track.album].compactMap { $0 }.joined(separator: " · "),
                                            artwork: CoverArt(url: track.artworkURL.flatMap(URL.init(string:)), seed: track.title, size: 40),
                                            state: model.region == .both ? .synced : .pending)
                    .listRowBackground(Color.canvasRaised)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            StepBar(actionTitle: "Choose direction", isEnabled: overlap != nil, action: onNext) {
                Text("Link these two").font(.footnote).foregroundStyle(Color.inkMuted)
            }
        }
        .task { if model.overlap == nil { await model.loadOverlap() } }
    }
}

/// Two overlapping circles with the three counts.
struct VennView: View {
    let sourceOnly: Int
    let both: Int
    let targetOnly: Int
    let sourcePlatform: Platform

    var body: some View {
        let left = SeamPresentation.service(sourcePlatform).markColor
        let right = SeamPresentation.service(sourcePlatform.other).markColor
        ZStack {
            HStack(spacing: -70) {
                Circle().fill(left.opacity(0.2)).overlay(Circle().strokeBorder(left.opacity(0.7), lineWidth: 2))
                Circle().fill(right.opacity(0.2)).overlay(Circle().strokeBorder(right.opacity(0.7), lineWidth: 2))
            }
            .frame(height: 170)
            HStack {
                count(sourceOnly, "\(sourcePlatform.rawValue) only", .ink)
                count(both, "Both", .thread)
                count(targetOnly, "\(sourcePlatform.other.rawValue) only", .ink)
            }
            .padding(.horizontal, Space.s6)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
    }

    private func count(_ n: Int, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 0) {
            Text("\(n)").font(.metric).foregroundStyle(tint)
            Text(label).font(.caption).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct DotLabelStyle: LabelStyle {
    let platform: Platform
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.s1 + 2) {
            PlatformDot(service: SeamPresentation.service(platform))
            configuration.title
        }
    }
}

// MARK: - 4. How to sync

struct HowToSyncStep: View {
    let model: NewSeamModel
    let onPreview: (UUID) -> Void
    @State private var isCreating = false
    @State private var error: String?

    var body: some View {
        @Bindable var model = model
        let source = model.source
        let twoWay = model.direction == .bidirectional
        List {
            if let source {
                SeamLine(
                    leading: CoverArt(url: source.artworkURL, seed: source.name, size: 96, service: SeamPresentation.service(source.platform)),
                    trailing: CoverArt(seed: model.targetName, size: 96, service: SeamPresentation.service(source.platform.other)),
                    direction: twoWay ? .twoWay : .oneWay, isMonitoring: model.keepWatching, style: .hero
                )
                .padding(.horizontal, Space.s6)
                .plainRow()
            }
            DirectionPicker(
                selection: Binding(
                    get: { twoWay ? .twoWay : .oneWay },
                    set: { model.direction = $0 == .twoWay ? .bidirectional : (source?.platform == .appleMusic ? .appleToSpotify : .spotifyToApple) }
                ),
                consequence: model.consequence
            )
            .plainRow()
            Section {
                if twoWay {
                    MonitorToggle("Ask before removing",
                                  description: model.mirrorRemovals
                                    ? "If you delete a track on one side, Antiphon removes it on the other too."
                                    : "If you delete a track on one side, Antiphon asks first.",
                                  isOn: Binding(get: { !model.mirrorRemovals }, set: { model.mirrorRemovals = !$0 }))
                } else {
                    MonitorToggle("Remove tracks too",
                                  description: RulesCopy.removal(model.removalPolicy, direction: model.direction),
                                  isOn: $model.mirrorRemovals)
                }
                MonitorToggle("Keep watching",
                              description: RulesCopy.monitoring(isOn: model.keepWatching, interval: model.interval, direction: model.direction),
                              isOn: $model.keepWatching)
            }
            .listRowBackground(Color.canvasRaised)
            if model.keepWatching {
                ChipBar(RulesCopy.intervals.map { .init($0, RulesCopy.intervalLabel($0)) }, selection: $model.interval).plainRow()
            }
            Banner(tone: .thread, symbol: "info.circle", title: "Track order", message: model.orderNote).plainRow()
            if let error {
                Banner(tone: .failed, symbol: "exclamationmark.triangle.fill", title: "Couldn't link the playlists", message: error).plainRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .animation(.smooth, value: model.direction)
        .navigationTitle("How to sync")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button(isCreating ? "Linking…" : "Preview changes") {
                isCreating = true
                Task {
                    defer { isCreating = false }
                    do { onPreview(try await model.createSeam()) }
                    catch { self.error = "Antiphon couldn't save the seam. Try again." }
                }
            }
            .buttonSizing(.flexible)
            .glassButton(.primary)
            .disabled(isCreating)
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s2)
        }
    }
}
