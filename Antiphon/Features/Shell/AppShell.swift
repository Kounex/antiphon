import AntiphonDesign
import SwiftUI

/// The root: Syncs, Library, Activity and Search on the Liquid Glass tab bar,
/// the account button into Settings, and the sync accessory while syncs run.
struct AppShell: View {
    @State private var model: AppShellModel
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @Environment(SpotifyAuthManager.self) private var spotifyAuth

    init(model: AppShellModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        @Bindable var model = model
        let running = model.runningSync(syncCoordinator.syncProgress)

        TabView(selection: $model.selectedTab) {
            Tab(AntiphonTab.syncs.title, systemImage: AntiphonTab.syncs.symbol, value: AppShellModel.Tab.syncs) {
                // Every sync starts from a preview.
                SyncsRoot(shell: model, onSyncNow: { model.syncFlowSeamId = $0 })
            }
            .badge(AntiphonTab.syncsBadge(reviewCount: model.reviewCount))

            Tab(AntiphonTab.library.title, systemImage: AntiphonTab.library.symbol, value: AppShellModel.Tab.library) {
                LibraryRoot(shell: model)
            }

            Tab(AntiphonTab.activity.title, systemImage: AntiphonTab.activity.symbol, value: AppShellModel.Tab.activity) {
                ActivityRoot(shell: model)
            }

            Tab(value: AppShellModel.Tab.search, role: .search) {
                SearchRoot(shell: model)
            }
        }
        .antiphonTabBar()
        .modifier(SyncAccessoryModifier(running: running) { running in
            // Back to the live sheet (Pause, Hide); several at once: a list of them.
            if let seamId = running.seamId {
                model.syncFlowSeamId = seamId
            } else {
                model.showsRunningSyncs = true
            }
        })
        .sheet(isPresented: $model.showsRunningSyncs, onDismiss: {
            if let seamId = model.pendingSyncFlowSeam {
                model.pendingSyncFlowSeam = nil
                model.syncFlowSeamId = seamId
            }
        }) {
            RunningSyncsSheet(rows: RunningSyncSummary.rows(progress: syncCoordinator.syncProgress, seams: model.seams)) { seamId in
                model.pendingSyncFlowSeam = seamId
                model.showsRunningSyncs = false
            } onClose: {
                model.showsRunningSyncs = false
            }
        }
        .sheet(isPresented: $model.showsNewSeam, onDismiss: {
            model.newSeamSource = nil
            Task {
                await model.refresh()
                await model.libraryModel.load()
            }
        }) {
            NewSeamFlowView(model: model.makeNewSeam(), makeSyncFlow: model.makeSyncFlow, onReview: openSeam)
        }
        .sheet(item: $model.syncFlowSeamId, onDismiss: {
            Task {
                await model.refresh()
                if let seamId = model.pendingConflictSeam {
                    model.pendingConflictSeam = nil
                    await model.openFirstConflict(seamId: seamId)
                }
            }
        }) { seamId in
            NavigationStack {
                SyncFlowView(model: model.makeSyncFlow(seamId: seamId),
                             onReview: openSeam, onNext: {}, onDone: { model.syncFlowSeamId = nil },
                             onConflicts: { id in
                                 model.pendingConflictSeam = id
                                 model.syncFlowSeamId = nil
                             })
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Close", systemImage: "xmark") { model.syncFlowSeamId = nil }.tint(.ink)
                        }
                    }
            }
            .tint(.thread)
        }
        .fullScreenCover(item: $model.reviewTarget, onDismiss: { Task { await model.refresh() } }) { target in
            ReviewQueueView(model: model.makeReviewQueue(target), makeDetail: model.makeMatchDetail) {
                model.reviewTarget = nil
            }
            .tint(.thread)
        }
        .sheet(item: $model.openConflict, onDismiss: { Task { await model.refresh() } }) { presentation in
            ConflictSheet(model: ConflictModel(item: presentation.item, others: presentation.others, sync: model.sync)) {
                model.openConflict = nil
            }
        }
        .sheet(isPresented: $model.showsSettings, onDismiss: { Task { await model.refresh() } }) {
            SettingsView(model: model.makeSettings())
        }
        .task(id: syncCoordinator.syncingPairIds) { await model.refresh() }
        // Badges, the accessory's seam names and Problems follow every store change.
        .task(id: StoreChanges.shared.revision) { await model.refresh() }
    }
}

/// Several syncs at once, from the accessory: each with its progress; a
/// row opens that sync's live sheet (Pause, Hide).
private struct RunningSyncsSheet: View {
    let rows: [RunningSync]
    let onOpen: (UUID) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            List(rows, id: \.seamId) { row in
                Button { if let seamId = row.seamId { onOpen(seamId) } } label: {
                    HStack(spacing: Space.s3) {
                        CoverArt(seed: row.seed, size: 40, cornerRadius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.body.weight(.semibold)).foregroundStyle(Color.ink).lineLimit(1)
                            Text(row.detail).font(.footnote.monospacedDigit()).foregroundStyle(Color.inkMuted)
                        }
                        Spacer(minLength: Space.s2)
                        ProgressRing(fraction: row.total > 0 ? Double(row.done) / Double(row.total) : 0)
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("Opens the sync")
                .listRowBackground(Color.canvasRaised)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Syncing now")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark", action: onClose).tint(.ink)
                }
            }
            .overlay {
                if rows.isEmpty { ContentUnavailableView("All done", systemImage: "checkmark.circle") }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(.thread)
    }
}

extension AppShell {
    /// Opens a seam's close matches in the review queue.
    func openSeam(_ seamId: UUID) {
        model.syncFlowSeamId = nil
        model.showsNewSeam = false
        model.selectedTab = .syncs
        model.syncsPath = [.seam(seamId)]
        model.reviewTarget = .init(seamId: seamId)
    }
}

extension UUID: @retroactive Identifiable {
    public var id: UUID { self }
}

/// The account button every tab root shows in its toolbar.
struct AccountButton: View {
    let initials: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let initials {
                Text(initials)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.ink)
            } else {
                Image(systemName: "person.crop.circle")
            }
        }
        .accessibilityLabel("Account and settings")
    }
}

/// Shows the accessory only while something syncs. `isEnabled:` needs iOS 26.1.
private struct SyncAccessoryModifier: ViewModifier {
    let running: RunningSync?
    let onTap: (RunningSync) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: running != nil) { accessory }
        } else if running != nil {
            content.tabViewBottomAccessory { accessory }
        } else {
            content
        }
    }

    @ViewBuilder
    private var accessory: some View {
        if let running {
            Button { onTap(running) } label: {
                SyncAccessory(
                    title: running.title, detail: running.detail, done: running.done, total: running.total,
                    artwork: CoverArt(seed: running.seed, size: 32, cornerRadius: 8)
                )
                // The whole capsule takes the tap, not only the text and the ring.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint(running.seamId == nil ? "Lists the syncs" : "Opens the sync")
        }
    }
}
