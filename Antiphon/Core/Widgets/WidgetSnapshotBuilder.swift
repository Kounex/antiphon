import Foundation
import SwiftData
import WidgetKit

extension WidgetSnapshot {
    /// The snapshot for `seams` and their History at `now`.
    static func build(seams: [SeamSummary], runs: [RunRecord], now: Date) -> WidgetSnapshot {
        let rows = seams.map { seam in
            Seam(id: seam.id, name: seam.name, artworkURL: seam.side(seam.source).artworkURL,
                 status: status(of: seam), checkedAt: seam.lastCheckedAt)
        }
        .sorted { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            return (a.checkedAt ?? .distantPast) > (b.checkedAt ?? .distantPast)
        }

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        // A first sync copies a whole playlist; that isn't news.
        let recent = runs.filter { $0.date >= weekAgo && $0.undoneAt == nil && $0.trigger != .undo && $0.trigger != .firstSync }
        let added = recent.map { run in (run.seamId, run.changes.filter { $0.kind == .add }.count) }.filter { $0.1 > 0 }

        return WidgetSnapshot(
            generatedAt: now,
            seams: rows,
            tracksInSync: seams.reduce(0) { $0 + $1.counts.synced },
            seamCount: seams.count,
            lastCheckedAt: seams.compactMap(\.lastCheckedAt).max(),
            newThisWeek: NewTracks(tracks: added.reduce(0) { $0 + $1.1 }, playlists: Set(added.map(\.0)).count)
        )
    }

    private static func status(of seam: SeamSummary) -> Status {
        if seam.counts.review > 0 { return .review(seam.counts.review) }
        if seam.lastResult == .failed { return .failed }
        if seam.isPaused { return .paused }
        return .inSync
    }

    private static func rank(_ status: Status) -> Int {
        switch status {
        case .review: 0
        case .failed: 1
        case .inSync: 2
        case .paused: 3
        }
    }
}

/// Writes the widgets' snapshot to the App Group and asks WidgetKit to
/// reload. Called after syncs, decisions, Reset all and when the app goes to
/// the background; quietly does nothing without an App Group (tests,
/// previews). Refreshes run one at a time, so the last one reads the latest
/// state; a failed read leaves the previous snapshot in place.
actor WidgetSnapshotWriter {
    private static let shared = WidgetSnapshotWriter()

    static func refresh(modelContainer: ModelContainer) async {
        await shared.write(modelContainer: modelContainer)
    }

    /// For callers that shouldn't wait (a review tap, a finished sync).
    static func schedule(modelContainer: ModelContainer) {
        Task { await refresh(modelContainer: modelContainer) }
    }

    private func write(modelContainer: ModelContainer) async {
        guard let folder = AppGroup.containerURL else { return }
        let repository = SwiftDataSeamRepository(modelContainer: modelContainer)
        do {
            let seams = try await repository.seams()
            let runs = try await repository.runs()
            try WidgetSnapshot.build(seams: seams, runs: runs, now: Date()).write(to: folder)
            WidgetCenter.shared.reloadAllTimelines()
        } catch {
            print("[Widgets] Snapshot not updated: \(error.localizedDescription)")
        }
    }
}
