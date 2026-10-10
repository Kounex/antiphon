import AntiphonDesign
import SwiftUI

/// Preview, then the live sheet, then the result.
struct SyncFlowView: View {
    @State var model: SyncFlowModel
    var nextName: String? = nil
    let onReview: (UUID) -> Void
    let onNext: () -> Void
    let onDone: () -> Void

    @Environment(SyncCoordinator.self) private var coordinator
    @State private var showsSyncing = false

    var body: some View {
        Group {
            if case .done(let result) = model.phase {
                SyncedView(model: model, result: result, nextName: nextName,
                           onReview: { onReview(model.seamId) }, onNext: onNext, onDone: onDone)
            } else {
                SyncPreviewView(model: model, onDone: onDone)
            }
        }
        .sheet(isPresented: $showsSyncing) {
            SyncingView(model: model, onHide: onDone)
                .presentationDetents([.medium, .large])
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
                .interactiveDismissDisabled()
        }
        .onChange(of: isSyncing) { _, syncing in showsSyncing = syncing }
        .onChange(of: coordinator.isSyncing(model.seamId)) { wasSyncing, nowSyncing in
            guard wasSyncing, !nowSyncing, case .syncing = model.phase,
                  let result = coordinator.lastResults[model.seamId] else { return }
            Task { await model.finished(with: result) }
        }
        .task {
            #if DEBUG
            if DebugRoute.flowPhase != nil { await model.debugApplyRoute(coordinator: coordinator); return }
            #endif
            if model.planned == nil { await model.load() }
        }
    }

    private var isSyncing: Bool {
        if case .syncing = model.phase { return true }
        return false
    }
}
