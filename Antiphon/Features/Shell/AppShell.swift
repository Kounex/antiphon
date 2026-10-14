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
                SyncsRoot(shell: model, onSyncNow: { model.openSyncFlow(seamId: $0) })
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
            // Reopens wherever we are — a sheet over the current screen,
            // never a tab or navigation change. One running sync reopens
            // focused on it; several open the browsable carousel.
            model.reopenRunningSyncs(ids: Array(syncCoordinator.syncingPairIds), focus: running.seamId)
        })
        .sheet(isPresented: $model.showsSyncSheet, onDismiss: {
            Task {
                await model.refresh()
                if let seamId = model.pendingConflictSeam {
                    model.pendingConflictSeam = nil
                    await model.openFirstConflict(seamId: seamId)
                }
            }
        }) {
            SyncFlowCarouselSheet(shell: model, onReview: openSeam) { id in
                model.pendingConflictSeam = id
            }
        }
        .sheet(isPresented: $model.showsNewSeam, onDismiss: {
            model.newSeamSource = nil
            Task {
                await model.refresh()
                await model.libraryModel.load()
            }
        }) {
            NewSeamFlowView(model: model.makeNewSeam(), makeSyncFlow: model.makeSyncFlow,
                            syncFlow: { model.syncFlowModels[$0] }, onReview: openSeam)
        }
        .fullScreenCover(item: $model.reviewTarget, onDismiss: { Task { await model.refresh() } }) { target in
            ReviewQueueView(model: model.makeReviewQueue(target), makePicker: model.makeReviewPicker) {
                model.reviewTarget = nil
            }
            .tint(.thread)
        }
        .sheet(item: $model.openConflict, onDismiss: { Task { await model.refresh() } }) { presentation in
            ConflictSheet(model: ConflictModel(item: presentation.item, others: presentation.others, sync: model.sync)) {
                model.openConflict = nil
            }
        }
        .sheet(item: $model.picking, onDismiss: { Task { await model.refresh() } }) { target in
            VersionPickerView(
                model: model.makeVersionPicker(target),
                onUse: { candidate in
                    try await model.sync.choose(candidate, for: target.key, seamId: target.seam.id).guided
                },
                onForget: { try await model.sync.forgetPick(for: target.key, seamId: target.seam.id) },
                onClose: { model.picking = nil }
            )
        }
        .sheet(isPresented: $model.showsSettings, onDismiss: { Task { await model.refresh() } }) {
            SettingsView(model: model.makeSettings())
        }
        .task(id: syncCoordinator.syncingPairIds) { await model.refresh() }
        // Badges, the accessory's seam names and Problems follow every store change.
        .task(id: StoreChanges.shared.revision) { await model.refresh() }
    }
}

extension AppShell {
    /// Opens a seam's close matches in the review queue.
    func openSeam(_ seamId: UUID) {
        model.closeSyncFlow(seamId: seamId)
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
