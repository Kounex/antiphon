import AntiphonDesign
import SwiftUI

/// Preview, then the live sheet, then the result.
struct SyncFlowView: View {
    @State var model: SyncFlowModel
    var nextName: String? = nil
    let onReview: (UUID) -> Void
    let onNext: () -> Void
    let onDone: () -> Void
    /// Opens the seam's removal questions.
    var onConflicts: (UUID) -> Void = { _ in }

    @Environment(SyncCoordinator.self) private var coordinator
    @State private var showsSyncing = false

    var body: some View {
        Group {
            if case .done(let result) = model.phase {
                SyncedView(model: model, result: result, nextName: nextName,
                           onReview: { onReview(model.seamId) }, onConflicts: { onConflicts(model.seamId) },
                           onNext: onNext, onDone: onDone)
            } else {
                SyncPreviewView(model: model, onDone: onDone)
            }
        }
        .sheet(isPresented: $showsSyncing) {
            SyncingView(model: model, onHide: hide)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
        .onChange(of: isSyncing) { _, syncing in
            // Recording a no-change check or removals needs no live sheet.
            showsSyncing = syncing && model.afterApply == .showResult
        }
        .onChange(of: coordinator.isSyncing(model.seamId)) { wasSyncing, nowSyncing in
            guard wasSyncing, !nowSyncing, case .syncing = model.phase,
                  let result = coordinator.lastResults[model.seamId] else { return }
            Task {
                await model.finished(with: result)
                if model.afterApply == .openConflicts, case .done = model.phase { onConflicts(model.seamId) }
            }
        }
        .task {
            // A flow discovered from the accessory (a sync this view never
            // previewed) never gets its seam loaded otherwise.
            await model.loadSeamIfNeeded()
            // Reopened after "Hide": the model may already be mid-sync (or
            // just caught up to a result that landed while hidden) — show
            // its live sheet right away instead of waiting for a phase
            // transition that already happened off-screen.
            await model.reconcile(with: coordinator)
            showsSyncing = isSyncing && model.afterApply == .showResult
            #if DEBUG
            if DebugRoute.flowPhase != nil { await model.debugApplyRoute(coordinator: coordinator); return }
            #endif
            if coordinator.isSyncing(model.seamId), model.planned == nil {
                model.followRunningSync()
                showsSyncing = true
                return
            }
            if model.planned == nil { await model.load() }
        }
    }

    /// Closes the live sheet first, then the flow: dismissing both at once
    /// delayed the accessory above the tab bar.
    private func hide() {
        showsSyncing = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            onDone()
        }
    }

    private var isSyncing: Bool {
        if case .syncing = model.phase { return true }
        return false
    }
}
