import AntiphonDesign
import SwiftData
import SwiftUI

enum ActivityRoute: Hashable {
    case run(UUID)
}

/// The Activity tab: History and New tracks, and one sync in detail.
struct ActivityRoot: View {
    let shell: AppShellModel

    var body: some View {
        @Bindable var shell = shell
        let model = shell.activityModel
        NavigationStack(path: $shell.activityPath) {
            ActivityView(model: model) { track in
                Task {
                    shell.picking = try? await shell.seamRepository.pickTarget(
                        seamId: track.seamId, added: TrackKey(platform: track.landedOn, id: track.landedTrackId), isrc: track.isrc)
                }
            }
                .toolbar {
                    if model.tab == .newTracks, !model.newTracks.isEmpty {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Mark all seen") { Task { await model.markAllSeen() } }.tint(.ink)
                        }
                        ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        AccountButton(initials: shell.accountInitials) { shell.showsSettings = true }
                    }
                }
                .navigationDestination(for: ActivityRoute.self) { route in
                    switch route {
                    case .run(let id): RunDetailView(model: shell.makeRunDetail(id)) { shell.openSeamDetail($0) }.id(id)
                    }
                }
        }
    }
}

struct ActivityView: View {
    let model: ActivityModel
    /// A New tracks row: opens the version picker for that song.
    var onOpenNewTrack: (NewTrack) -> Void = { _ in }

    var body: some View {
        @Bindable var model = model
        List {
            Picker("Show", selection: $model.tab) {
                Text("History").tag(ActivityModel.Tab.history)
                Text(model.newTracks.isEmpty ? "New tracks" : "New tracks \(model.newTracks.count)").tag(ActivityModel.Tab.newTracks)
            }
            .pickerStyle(.segmented)
            .plainRow()

            if let error = model.loadError {
                Banner(tone: .failed, symbol: "exclamationmark.triangle.fill", title: "History didn't load", message: error).plainRow()
            }
            switch model.tab {
            case .history: history
            case .newTracks: newTracks
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Activity")
        .refreshable { await model.load() }
        .task(id: StoreChanges.shared.revision) { await model.load() }
    }

    // MARK: - History

    @ViewBuilder
    private var history: some View {
        WeekCard(week: model.week).plainRow()
        if model.sections.isEmpty, !model.isLoading {
            ContentUnavailableView("No syncs yet", systemImage: "clock.arrow.circlepath",
                                   description: Text("Every sync shows up here, with what it changed and a way to undo it."))
                .plainRow()
        }
        ForEach(model.sections) { section in
            Section(section.title) {
                ForEach(section.entries) { entry in
                    switch entry {
                    case .run(let run):
                        NavigationLink(value: ActivityRoute.run(run.id)) { RunRow(run: run) }
                    case .quiet(let quiet):
                        QuietRow(quiet: quiet)
                    }
                }
            }
            .listRowBackground(Color.canvasRaised)
        }
    }

    // MARK: - New tracks

    @ViewBuilder
    private var newTracks: some View {
        Text(model.sinceText).font(.subheadline).foregroundStyle(Color.inkMuted).plainRow()
        ForEach(model.groups) { group in
            NewTrackSection(group: group, now: model.currentDate, onOpen: onOpenNewTrack)
        }
    }
}

/// "Is it working?" at a glance: tracks per day this week, failures in orange.
struct WeekCard: View {
    let week: WeekChart

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(ActivityCopy.weekLine(week)).font(.headline).foregroundStyle(Color.ink)
                Spacer(minLength: Space.s2)
                Text("\(week.failed) failed")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(week.failed > 0 ? Color.statusFailed : Color.inkMuted)
                    .padding(.horizontal, Space.s2).padding(.vertical, 3)
                    .background(week.failed > 0 ? Color.statusFailedSoft : Color.canvas, in: .capsule)
            }
            let peak = max(1, week.days.map { $0.synced + $0.failed }.max() ?? 1)
            HStack(alignment: .bottom, spacing: Space.s2) {
                ForEach(Array(week.days.enumerated()), id: \.offset) { _, day in
                    VStack(spacing: Space.s1) {
                        VStack(spacing: 2) {
                            Spacer(minLength: 0)
                            if day.failed > 0 {
                                RoundedRectangle(cornerRadius: 3).fill(Color.statusFailed)
                                    .frame(height: max(4, 64 * CGFloat(day.failed) / CGFloat(peak)))
                            }
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day.synced > 0 ? Color.statusSynced : Color.inkFaint.opacity(0.3))
                                .frame(height: day.synced > 0 ? max(4, 64 * CGFloat(day.synced) / CGFloat(peak)) : 3)
                        }
                        .frame(height: 68)
                        Text(day.label)
                            .font(.caption2.weight(day.isToday ? .bold : .regular))
                            .foregroundStyle(day.isToday ? Color.ink : Color.inkMuted)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(week.days.map { "\($0.label): \($0.synced)" }.joined(separator: ", "))
        }
        .padding(Space.s4)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
    }
}

struct RunRow: View {
    let run: RunRecord

    var body: some View {
        HStack(spacing: Space.s3) {
            CoverArt(seed: run.seamName, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(run.seamName).font(.headline).foregroundStyle(Color.ink)
                Text(ActivityCopy.line(run))
                    .font(.subheadline)
                    .foregroundStyle(run.result == .failed ? Color.statusFailed : Color.inkMuted)
            }
            Spacer(minLength: Space.s2)
            Text(run.date, format: .dateTime.hour().minute())
                .font(.footnote.monospacedDigit()).foregroundStyle(Color.inkMuted)
        }
        .opacity(run.undoneAt == nil ? 1 : Opacity.missing)
    }
}

struct QuietRow: View {
    let quiet: QuietChecks

    var body: some View {
        HStack(spacing: Space.s3) {
            Image(systemName: "checkmark.circle")
                .font(.title3).foregroundStyle(Color.inkFaint)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(quiet.seamName).font(.subheadline.weight(.semibold)).foregroundStyle(Color.inkMuted)
                Text(ActivityCopy.quietLine(quiet)).font(.footnote).foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: Space.s2)
            Text(quiet.latest, format: .dateTime.hour().minute())
                .font(.footnote.monospacedDigit()).foregroundStyle(Color.inkFaint)
        }
        .accessibilityElement(children: .combine)
    }
}

/// One seam's arrivals. Long lists show the first four, then "N more".
struct NewTrackSection: View {
    let group: NewTrackGroup
    let now: Date
    /// Opens the version picker for the song.
    var onOpen: (NewTrack) -> Void = { _ in }
    @State private var expanded = false

    private static let preview = 4

    var body: some View {
        Section {
            ForEach(expanded ? group.tracks : Array(group.tracks.prefix(Self.preview))) { track in
                Button { onOpen(track) } label: {
                    AntiphonDesign.TrackRow(
                        title: track.title,
                        detail: "\(track.artist) · \(ActivityCopy.origin(track, now: now))",
                        artwork: CoverArt(url: track.artworkURL, seed: track.title, size: 40,
                                          service: SeamPresentation.service(track.landedOn.other)),
                        state: .plain
                    )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Choose the version")
            }
            if !expanded, group.tracks.count > Self.preview {
                Button("\(group.tracks.count - Self.preview) more") { withAnimation { expanded = true } }
                    .tint(.thread)
            }
        } header: {
            HStack(spacing: Space.s2) {
                Text(group.seamName)
                Text(group.directionText).foregroundStyle(Color.inkFaint)
            }
        }
        .listRowBackground(Color.canvasRaised)
    }
}

/// One sync in detail. Any sync can be undone from here; the button's
/// explanation lists exactly what reverting touches.
struct RunDetailView: View {
    @State var model: RunDetailModel
    let onOpenSeam: (UUID) -> Void

    var body: some View {
        List {
            if let run = model.record {
                VStack(spacing: Space.s1) {
                    Text(run.seamName).font(.antiphonTitle1).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                    Text(ActivityCopy.started(run)).font(.footnote).foregroundStyle(Color.inkMuted)
                    if run.undoneAt != nil {
                        Text("Undone").font(.footnote.weight(.semibold)).foregroundStyle(Color.statusReview)
                    }
                }
                .frame(maxWidth: .infinity)
                .plainRow()

                Section {
                    ForEach(ActivityCopy.counts(run), id: \.self) { count in
                        LabeledContent(count.title) {
                            Text(count.value).font(.body.monospacedDigit().weight(.semibold)).foregroundStyle(Color.ink)
                        }
                    }
                }
                .listRowBackground(Color.canvasRaised)

                if !run.changes.isEmpty {
                    Section {
                        ForEach(Array(run.changes.enumerated()), id: \.offset) { _, change in
                            HStack(spacing: Space.s3) {
                                CoverArt(url: change.artworkURL, seed: change.title, size: 40,
                                         service: SeamPresentation.service(change.platform))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.title).font(.headline).foregroundStyle(Color.ink)
                                    Text(ActivityCopy.evidence(change)).font(.subheadline).foregroundStyle(Color.inkMuted)
                                }
                                Spacer(minLength: Space.s2)
                                Image(systemName: symbol(change.kind))
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(change.kind == .add ? Color.statusSynced : Color.inkMuted)
                                    .accessibilityLabel(change.kind == .add ? "Added" : change.kind == .remove ? "Removed" : "Moved")
                            }
                        }
                    }
                    .listRowBackground(Color.canvasRaised)
                }

                if let message = model.message {
                    Banner(tone: model.messageIsError ? .failed : .thread,
                           symbol: model.messageIsError ? "exclamationmark.triangle.fill" : "arrow.uturn.backward.circle.fill",
                           title: model.messageIsError ? "Not undone" : "Undone", message: message)
                        .plainRow()
                }

                if model.canUndo {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Button(role: .destructive) {
                            Task { await model.undo() }
                        } label: {
                            Label(model.isUndoing ? "Undoing…" : "Undo this sync", systemImage: "arrow.uturn.backward")
                        }
                        .buttonSizing(.flexible)
                        .glassButton(.secondary)
                        .disabled(model.isUndoing)
                        if let explanation = model.undoExplanation {
                            Text(explanation).font(.footnote).foregroundStyle(Color.inkMuted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .plainRow()
                }
            } else {
                ProgressView().frame(maxWidth: .infinity).plainRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(model.record.map { title(for: $0.date) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let run = model.record {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Open seam", systemImage: "link") { onOpenSeam(run.seamId) }.tint(.ink)
                }
            }
        }
        .task { await model.load() }
        // History changes (an undo, a new run): the record follows; the undo
        // preview, which reads the playlists, doesn't refetch on every change.
        .task(id: StoreChanges.shared.revision) { await model.reloadRecord() }
    }

    private func symbol(_ kind: ChangeKind) -> String {
        switch kind {
        case .add: "plus"
        case .remove: "minus"
        case .move: "arrow.up.arrow.down"
        }
    }

    /// "Today, 14:32".
    private func title(for date: Date) -> String {
        let day = ActivityHistory.title(for: Calendar.current.startOfDay(for: date), now: Date(), calendar: .current)
        return "\(day), \(date.formatted(date: .omitted, time: .shortened))"
    }
}
