import AntiphonDesign
import SwiftUI

/// "Sync now": one seam's preview, with the live glass sheet on top once it
/// syncs. Hide puts the whole thing away; the sync keeps going.
struct SyncPreviewSheet: View {
    let shell: AppShellModel
    let seamId: UUID
    let onReview: (UUID) -> Void
    let onConflicts: (UUID) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if let model = shell.syncFlowModels[seamId] {
                    SyncFlowView(
                        model: model, onReview: onReview, onNext: {},
                        onDone: { shell.closeSyncFlow(seamId: seamId) },
                        onHide: { shell.closePreview() },
                        onConflicts: onConflicts
                    )
                    // A new flow is a new view: no live-sheet state carries over.
                    .id(ObjectIdentifier(model))
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { shell.closePreview() }.tint(.ink)
                }
            }
        }
        .tint(.thread)
    }
}

/// The bar above the tabs: only the live glass sheet, over whatever is open.
/// Each sync shows its progress (Pause, Hide), then its result once it's
/// done. Several at once: a strip of covers switches between them.
struct LiveSyncSheet: View {
    let shell: AppShellModel
    let onReview: (UUID) -> Void
    let onConflicts: (UUID) -> Void

    @Environment(SyncCoordinator.self) private var coordinator
    @State private var detent: PresentationDetent = SyncingView.collapsed

    private var ids: [UUID] { shell.liveSeamIds }

    /// The shell's focus is the only one: it's right from the first frame.
    private var focused: UUID? {
        shell.focusedLiveSeamId.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
    }

    private var focusedIsDone: Bool {
        guard let id = focused, case .done = shell.syncFlowModels[id]?.phase else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            if ids.count > 1 {
                SyncStrip(shell: shell, ids: ids, focused: focused)
            }
            if let id = focused, let model = shell.syncFlowModels[id] {
                LivePage(model: model, onHide: { shell.hideLiveSheet() }, onDone: { shell.closeSyncFlow(seamId: id) },
                         onReview: onReview, onConflicts: onConflicts)
                    .id(id)
                    .transition(.opacity)
            } else {
                ContentUnavailableView("All done", systemImage: "checkmark.circle")
            }
        }
        .animation(.smooth, value: focused)
        .presentationDetents([SyncingView.collapsed, .large], selection: $detent)
        // A result needs the room; progress fits the collapsed glass.
        .onChange(of: focusedIsDone, initial: true) { _, done in detent = done ? .large : SyncingView.collapsed }
        // Pages that aren't mounted still catch up to a sync that finished
        // while the sheet was away (their chip shows it), and get their covers.
        .task(id: ids) {
            for id in ids {
                guard let flow = shell.syncFlowModels[id] else { continue }
                await flow.loadSeamIfNeeded()
                if await flow.reconcile(with: coordinator), flow.asksAboutRemovals {
                    onConflicts(id)
                    return
                }
            }
        }
        .tint(.thread)
    }
}

/// One sync in the glass sheet: its live progress, then its result.
private struct LivePage: View {
    let model: SyncFlowModel
    let onHide: () -> Void
    let onDone: () -> Void
    let onReview: (UUID) -> Void
    let onConflicts: (UUID) -> Void

    var body: some View {
        Group {
            switch model.phase {
            case .syncing:
                SyncingView(model: model, onHide: onHide)
            case .done(let result):
                SyncedView(model: model, result: result, nextName: nil,
                           onReview: { onReview(model.seamId) }, onConflicts: { onConflicts(model.seamId) },
                           onNext: {}, onDone: onDone)
            case .planning, .preview, .failed:
                // The playlists changed under the sync: it needs a new preview.
                ContentUnavailableView {
                    Label("The playlists changed", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("Nothing more was synced. Use Sync now on the seam to see what changes now.")
                } actions: {
                    Button("Done", action: onDone).glassButton(.secondary)
                }
            }
        }
        .modifier(FollowsSyncToItsResult(model: model, onConflicts: onConflicts))
    }
}

/// Several syncs at once: small covers to switch between, each with its own
/// progress ring, or a checkmark once it's done.
private struct SyncStrip: View {
    let shell: AppShellModel
    let ids: [UUID]
    let focused: UUID?
    @Environment(SyncCoordinator.self) private var coordinator

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(ids, id: \.self) { id in chip(for: id) }
            }
            .padding(.horizontal, Space.s4)
        }
        .padding(.top, Space.s4)
        .padding(.bottom, Space.s2)
    }

    private func chip(for id: UUID) -> some View {
        let model = shell.syncFlowModels[id]
        let name = model?.seam?.name ?? "Seam"
        let isFocused = focused == id
        return Button {
            withAnimation(.smooth) { shell.focusedLiveSeamId = id }
        } label: {
            HStack(spacing: Space.s1 + 2) {
                ZStack(alignment: .bottomTrailing) {
                    CoverArt(seed: name, size: 26, cornerRadius: 7)
                    status(id: id, model: model).offset(x: 3, y: 3)
                }
                Text(name)
                    .font(.footnote.weight(isFocused ? .semibold : .regular))
                    .foregroundStyle(isFocused ? Color.ink : Color.inkMuted)
                    .lineLimit(1)
            }
            .padding(.leading, Space.s1)
            .padding(.trailing, Space.s3)
            .padding(.vertical, Space.s1 + 2)
        }
        .buttonStyle(.plain)
        .glassEffect(isFocused ? .regular.tint(.thread.opacity(0.22)) : .regular, in: .capsule)
        .accessibilityAddTraits(isFocused ? .isSelected : [])
        .accessibilityLabel(name)
    }

    @ViewBuilder
    private func status(id: UUID, model: SyncFlowModel?) -> some View {
        let dot: CGFloat = 13
        if case .done(let result) = model?.phase {
            Circle()
                .fill(result.status == .failed ? Color.statusFailed : Color.statusSynced)
                .overlay {
                    Image(systemName: result.status == .failed ? "exclamationmark" : "checkmark")
                        .font(.system(size: 7, weight: .bold)).foregroundStyle(Color.canvas)
                }
                .frame(width: dot, height: dot)
        } else if let progress = coordinator.syncProgress[id] {
            MiniProgressRing(fraction: progress.fraction).frame(width: dot, height: dot)
        } else {
            Circle().fill(Color.inkFaint).frame(width: dot, height: dot)
        }
    }
}

/// A chip-sized progress ring, matching the accessory's colors at a smaller size.
private struct MiniProgressRing: View {
    let fraction: Double

    var body: some View {
        ZStack {
            Circle().stroke(Color.canvas, lineWidth: 2)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Color.thread, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
        }
    }
}
