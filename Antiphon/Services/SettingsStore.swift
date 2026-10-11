import Foundation
import SwiftData

/// What the accounts are used for, for Settings and account pages.
struct AccountUsage: Equatable, Sendable {
    var seams: Int
    var tracksInSync: Int
    var madeOnSpotify: Int
    var madeOnAppleMusic: Int

    static let empty = AccountUsage(seams: 0, tracksInSync: 0, madeOnSpotify: 0, madeOnAppleMusic: 0)
}

/// Settings' reads and the two whole-store actions.
protocol SettingsStore: Sendable {
    func usage() async throws -> AccountUsage
    /// Match confidences of tracks matched in the last `days` days.
    func recentConfidences(days: Int) async throws -> [Int]
    /// Every recorded change, one per line.
    func historyCSV() async throws -> String
    /// Unlinks every seam and clears history. Playlists aren't touched.
    func resetAll() async throws
}

extension SwiftDataSeamRepository: SettingsStore {
    func usage() async throws -> AccountUsage {
        let context = ModelContext(modelContainerForReview)
        let pairs = try context.fetch(FetchDescriptor<SyncPair>())
        return AccountUsage(
            seams: pairs.count,
            tracksInSync: pairs.reduce(0) { $0 + SeamCounts(tracks: $1.cachedTracks, direction: $1.syncDirection, policy: $1.effectiveRemovalPolicy).synced },
            madeOnSpotify: pairs.filter(\.spotifyCreatedByAntiphon).count,
            madeOnAppleMusic: pairs.filter(\.appleMusicCreatedByAntiphon).count
        )
    }

    func recentConfidences(days: Int) async throws -> [Int] {
        let context = ModelContext(modelContainerForReview)
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        return try context.fetch(FetchDescriptor<CachedTrack>(predicate: #Predicate { $0.matchConfidence != nil }))
            .filter { ($0.lastSyncAttempt ?? $0.addedAt) >= since }
            .compactMap(\.matchConfidence)
    }

    func historyCSV() async throws -> String {
        let context = ModelContext(modelContainerForReview)
        let logs = try context.fetch(FetchDescriptor<SyncLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)]))
        let formatter = ISO8601DateFormatter()
        var lines = ["date,seam,started by,change,service,title,artist,confidence"]
        for log in logs {
            guard let pair = log.syncPair else { continue }
            let seam = pair.syncDirection == .appleToSpotify ? pair.appleMusicPlaylistName : pair.spotifyPlaylistName
            let trigger = (log.trigger ?? SyncTrigger(log.action)).rawValue
            for change in log.orderedChanges {
                lines.append([formatter.string(from: log.startedAt ?? log.timestamp), seam, trigger, change.kind.rawValue,
                              change.platform.rawValue, change.title, change.artist, change.confidence.map(String.init) ?? ""]
                    .map(Self.csvField).joined(separator: ","))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    func resetAll() async throws {
        let context = ModelContext(modelContainerForReview)
        // One by one: batch deletes trip over the run → change relationship.
        // Deleting a seam cascades to its tracks, runs, changes and problems;
        // anything left without a seam goes after it.
        for pair in try context.fetch(FetchDescriptor<SyncPair>()) { context.delete(pair) }
        try context.save()
        for change in try context.fetch(FetchDescriptor<SyncChange>()) { context.delete(change) }
        for log in try context.fetch(FetchDescriptor<SyncLog>()) { context.delete(log) }
        for row in try context.fetch(FetchDescriptor<CachedTrack>()) { context.delete(row) }
        for problem in try context.fetch(FetchDescriptor<SyncProblem>()) { context.delete(problem) }
        try context.save()
    }

    private static func csvField(_ value: String) -> String {
        guard value.contains(where: { ",\"\n".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

#if DEBUG
extension PreviewSeamRepository: SettingsStore {
    func usage() async throws -> AccountUsage {
        AccountUsage(seams: 9, tracksInSync: 1284, madeOnSpotify: 1, madeOnAppleMusic: 3)
    }
    func recentConfidences(days: Int) async throws -> [Int] {
        Array(repeating: 100, count: 380) + Array(repeating: 94, count: 18) + Array(repeating: 84, count: 14)
    }
    func historyCSV() async throws -> String { "date,seam,started by,change,service,title,artist,confidence\n" }
    func resetAll() async throws {}
}
#endif
