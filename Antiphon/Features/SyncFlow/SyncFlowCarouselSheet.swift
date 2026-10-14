import AntiphonDesign
import SwiftUI

/// The sync sheet: one running flow, shown exactly as before, or — with
/// several syncs going at once — a browsable carousel of them, each keeping
/// its own content. Opens over whatever's on screen and never changes the
/// tab or navigation underneath it.
struct SyncFlowCarouselSheet: View {
    let shell: AppShellModel
    let onReview: (UUID) -> Void
    let onConflicts: (UUID) -> Void

    var body: some View {
        let ids = shell.orderedSyncFlowSeamIds
        NavigationStack {
            Group {
                if ids.count > 1 {
                    SyncFlowCarousel(shell: shell, ids: ids, onReview: onReview, onConflicts: onConflicts)
                } else if let only = ids.first {
                    SyncFlowPage(shell: shell, seamId: only, onReview: onReview, onConflicts: onConflicts)
                } else {
                    ContentUnavailableView("All done", systemImage: "checkmark.circle")
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { shell.hideSyncSheet() }.tint(.ink)
                }
            }
        }
        .tint(.thread)
    }
}

/// One seam's flow, backed by its cached model so hiding and reopening the
/// sheet shows the same content.
private struct SyncFlowPage: View {
    let shell: AppShellModel
    let seamId: UUID
    let onReview: (UUID) -> Void
    let onConflicts: (UUID) -> Void

    var body: some View {
        if let model = shell.syncFlowModels[seamId] {
            SyncFlowView(
                model: model, onReview: onReview, onNext: {},
                onDone: { shell.closeSyncFlow(seamId: seamId) },
                onHide: { shell.hideSyncSheet() },
                onConflicts: { onConflicts($0); shell.closeSyncFlow(seamId: seamId) }
            )
        }
    }
}

/// Several syncs at once: a strip of small covers to switch between, each
/// with its own progress ring or a checkmark once it's done, and the focused
/// one's full content below — exactly the single-sync sheet, swapped in.
/// Only the focused flow is ever mounted: each one owns a live nested sheet
/// of its own (Pause, Hide), and two mounted at once would fight over it.
private struct SyncFlowCarousel: View {
    let shell: AppShellModel
    let ids: [UUID]
    let onReview: (UUID) -> Void
    let onConflicts: (UUID) -> Void

    @State private var focused: UUID?
    @Environment(SyncCoordinator.self) private var coordinator

    var body: some View {
        VStack(spacing: 0) {
            strip
            if let id = focused ?? ids.first {
                SyncFlowPage(shell: shell, seamId: id, onReview: onReview, onConflicts: onConflicts)
                    .id(id)
                    .transition(.opacity)
            }
        }
        .animation(.smooth, value: focused)
        .onAppear { focused = shell.focusedSyncSeamId ?? ids.first }
        .onChange(of: ids) { _, newIds in
            if let focused, !newIds.contains(focused) { self.focused = newIds.first }
        }
        // Every chip needs its name and cover, not just the focused page
        // that's actually mounted.
        .task(id: ids) {
            for id in ids { await shell.syncFlowModels[id]?.loadSeamIfNeeded() }
        }
    }

    private var focusBinding: Binding<UUID?> {
        Binding(get: { focused ?? ids.first }, set: { focused = $0 })
    }

    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Space.s2) {
                ForEach(ids, id: \.self) { id in chip(for: id) }
            }
            .padding(.horizontal, Space.s4)
        }
        .padding(.vertical, Space.s2)
        .background(.ultraThinMaterial)
    }

    private func chip(for id: UUID) -> some View {
        let model = shell.syncFlowModels[id]
        let name = model?.seam?.name ?? "Seam"
        let isFocused = focusBinding.wrappedValue == id
        return Button {
            withAnimation(.smooth) { focused = id }
        } label: {
            HStack(spacing: Space.s1 + 2) {
                ZStack(alignment: .bottomTrailing) {
                    CoverArt(seed: name, size: 26, cornerRadius: 7)
                    chipStatus(id: id, model: model).offset(x: 3, y: 3)
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
    private func chipStatus(id: UUID, model: SyncFlowModel?) -> some View {
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
