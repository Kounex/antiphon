import Foundation
import SwiftData
import UIKit
import WidgetKit

extension WidgetSnapshot {
    /// The snapshot for `seams` at `now`. "New this week" counts what
    /// Activity › New tracks lists (`newTracks`) from the last 7 days, so
    /// tapping it shows them.
    static func build(seams: [SeamSummary], newTracks: [NewTrack], now: Date) -> WidgetSnapshot {
        let rows = seams.map { seam in
            Seam(id: seam.id, name: seam.name, artworkURL: seam.side(seam.source).artworkURL,
                 status: status(of: seam), checkedAt: seam.lastCheckedAt)
        }
        .sorted { a, b in
            if rank(a.status) != rank(b.status) { return rank(a.status) < rank(b.status) }
            return (a.checkedAt ?? .distantPast) > (b.checkedAt ?? .distantPast)
        }

        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let recent = newTracks.filter { $0.date >= weekAgo }

        return WidgetSnapshot(
            generatedAt: now,
            seams: rows,
            tracksInSync: seams.reduce(0) { $0 + $1.counts.synced },
            seamCount: seams.count,
            lastCheckedAt: seams.compactMap(\.lastCheckedAt).max(),
            newThisWeek: NewTracks(tracks: recent.count, playlists: Set(recent.map(\.seamId)).count)
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
/// the background, and a moment after any other save (`followStoreChanges`);
/// quietly does nothing without an App Group (tests, previews). Refreshes
/// run one at a time, so the last one reads the latest state; a failed read
/// leaves the previous snapshot in place, and an unchanged one isn't
/// rewritten (iOS limits how often widgets reload from the background).
actor WidgetSnapshotWriter {
    private static let shared = WidgetSnapshotWriter()
    /// After a burst of saves (a sync saves after every track), wait this
    /// long for quiet before refreshing.
    private static let settleTime: Duration = .seconds(2)
    @MainActor private static var saveObserver: (any NSObjectProtocol)?

    private var written: WidgetSnapshot?
    private var pendingRefresh: Task<Void, Never>?

    /// Every save in the app, from any context (linking, unlinking, rules,
    /// pausing, syncs, answers, background runs), refreshes the widgets once
    /// the saves settle, so they don't fall behind what the app shows.
    @MainActor static func followStoreChanges(modelContainer: ModelContainer) {
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) { _ in
            Task { await shared.refreshWhenSettled(modelContainer: modelContainer) }
        }
    }

    private func refreshWhenSettled(modelContainer: ModelContainer) {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: Self.settleTime)
            guard !Task.isCancelled else { return }
            await write(modelContainer: modelContainer, covers: true)
        }
    }

    /// `covers`: download missing cover thumbnails. Background runs skip it
    /// to save their seconds; the next refresh in the app fetches them.
    static func refresh(modelContainer: ModelContainer, covers: Bool = true) async {
        await shared.write(modelContainer: modelContainer, covers: covers)
    }

    /// A saved cover for `url` (downloaded if needed), by file name in the
    /// App Group's covers folder.
    static func cover(for url: URL?) async -> String? {
        guard let url, let folder = AppGroup.containerURL else { return nil }
        return await shared.saveCover(url, in: folder) ? WidgetSnapshot.coverFile(for: url, in: folder).lastPathComponent : nil
    }

    /// For callers that shouldn't wait (a review tap, a finished sync).
    static func schedule(modelContainer: ModelContainer) {
        Task { await refresh(modelContainer: modelContainer) }
    }

    private func write(modelContainer: ModelContainer, covers: Bool) async {
        guard let folder = AppGroup.containerURL else { return }
        let repository = SwiftDataSeamRepository(modelContainer: modelContainer)
        do {
            let seams = try await repository.seams()
            let newTracks = try await repository.newTracks()
            let snapshot = WidgetSnapshot.build(seams: seams, newTracks: newTracks, now: Date())
            let previous = written ?? WidgetSnapshot.read(from: folder)
            if previous.map({ !snapshot.hasSameContent(as: $0) }) ?? true {
                try snapshot.write(to: folder)
                written = snapshot
                WidgetCenter.shared.reloadAllTimelines()
            }
            if covers, await saveCovers(for: snapshot, in: folder) {
                WidgetCenter.shared.reloadAllTimelines()
            }
        } catch {
            print("[Widgets] Snapshot not updated: \(error.localizedDescription)")
        }
    }

    /// Small copies of the covers the widgets show (the first seams), so
    /// the widget never downloads. Covers no longer shown are removed.
    /// Returns whether a cover was downloaded (the widgets reload to show it).
    @discardableResult
    private func saveCovers(for snapshot: WidgetSnapshot, in folder: URL) async -> Bool {
        let directory = folder.appending(path: WidgetSnapshot.coversFolder)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var keep = Set<String>()
        var downloaded = false
        for seam in snapshot.seams.prefix(3) {
            guard let url = seam.artworkURL else { continue }
            let file = WidgetSnapshot.coverFile(for: url, in: folder)
            keep.insert(file.lastPathComponent)
            let existed = FileManager.default.fileExists(atPath: file.path)
            if await saveCover(url, in: folder), !existed { downloaded = true }
        }
        // Covers no longer shown go after a day (a Live Activity may still use one).
        let dayAgo = Date().addingTimeInterval(-86_400)
        let existing = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in existing where !keep.contains(file.lastPathComponent) {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if modified < dayAgo { try? FileManager.default.removeItem(at: file) }
        }
        return downloaded
    }

    /// Downloads `url`'s artwork as a small cover unless it's there already.
    fileprivate func saveCover(_ url: URL, in folder: URL) async -> Bool {
        let file = WidgetSnapshot.coverFile(for: url, in: folder)
        if FileManager.default.fileExists(atPath: file.path) {
            // In use again: keep it out of the next prune.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return true
        }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        guard let (data, _) = try? await URLSession.shared.data(for: request), let image = UIImage(data: data),
              let thumbnail = Self.thumbnail(image) else { return false }
        return (try? thumbnail.write(to: file, options: .atomic)) != nil
    }

    /// A 120 pt square JPEG, cropped to fill.
    private static func thumbnail(_ image: UIImage) -> Data? {
        let side: CGFloat = 120
        let scale = max(side / image.size.width, side / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).jpegData(withCompressionQuality: 0.8) { _ in
            image.draw(in: CGRect(x: (side - size.width) / 2, y: (side - size.height) / 2, width: size.width, height: size.height))
        }
    }
}
