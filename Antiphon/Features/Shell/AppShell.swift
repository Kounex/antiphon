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
        .modifier(SyncAccessoryModifier(running: running))
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
        .sheet(isPresented: $model.showsSettings) {
            // Replaced by the new Settings in M8.
            SettingsView()
                .environment(\.colorScheme, .dark)
        }
        .task(id: syncCoordinator.syncingPairIds) { await model.refresh() }
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
            SyncAccessory(
                title: running.title, detail: running.detail, done: running.done, total: running.total,
                artwork: CoverArt(seed: running.seed, size: 32, cornerRadius: 8)
            )
        }
    }
}
