import Foundation
import SwiftData

/// Every sync run across seams, and the tracks monitoring brought in.
protocol ActivityRepository: Sendable {
    /// Newest first.
    func runs() async throws -> [RunRecord]
    func run(_ id: UUID) async throws -> RunRecord?
    /// Tracks monitoring added that haven't been marked seen.
    func newTracks() async throws -> [NewTrack]
    func markAllSeen() async throws
}

extension SwiftDataSeamRepository: ActivityRepository {
    /// Enough for weeks of history without reading every old run.
    private static let historyLimit = 400

    func runs() async throws -> [RunRecord] {
        let context = ModelContext(modelContainerForReview)
        var descriptor = FetchDescriptor<SyncLog>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        descriptor.fetchLimit = Self.historyLimit
        return try context.fetch(descriptor).compactMap(Self.record)
    }

    func run(_ id: UUID) async throws -> RunRecord? {
        let context = ModelContext(modelContainerForReview)
        return try context.fetch(FetchDescriptor<SyncLog>(predicate: #Predicate { $0.id == id })).first.flatMap(Self.record)
    }

    func newTracks() async throws -> [NewTrack] {
        let context = ModelContext(modelContainerForReview)
        return try unseenUnattendedAdds(in: context).compactMap { change in
            guard let run = change.run, let pair = run.syncPair else { return nil }
            return NewTrack(id: change.id, seamId: pair.id, seamName: Self.activityName(of: pair), direction: pair.syncDirection,
                            title: change.title, artist: change.artist, artworkURL: change.artworkURL.flatMap(URL.init(string:)),
                            landedOn: change.platform, date: run.startedAt ?? run.timestamp,
                            landedTrackId: change.platformTrackId, isrc: change.isrc)
        }
    }

    func markAllSeen() async throws {
        let context = ModelContext(modelContainerForReview)
        let now = Date()
        for change in try unseenUnattendedAdds(in: context) { change.seenAt = now }
        try context.save()
        WidgetSnapshotWriter.schedule(modelContainer: modelContainerForReview)
    }

    // MARK: - Private

    /// Adds Antiphon made on its own (`SyncTrigger.isUnattended`), not yet marked seen.
    private func unseenUnattendedAdds(in context: ModelContext) throws -> [SyncChange] {
        // Enum comparisons don't translate to SwiftData predicates: filter in memory.
        try context.fetch(FetchDescriptor<SyncChange>(predicate: #Predicate { $0.seenAt == nil }))
            .filter { $0.kind == .add && ($0.run?.trigger.map(\.isUnattended) ?? false) && $0.run?.undoneAt == nil }
    }

    private static func activityName(of pair: SyncPair) -> String {
        pair.syncDirection == .appleToSpotify ? pair.appleMusicPlaylistName : pair.spotifyPlaylistName
    }

    private static func record(_ log: SyncLog) -> RunRecord? {
        guard let pair = log.syncPair else { return nil }
        let changes = log.orderedChanges.map { change in
            RunChange(kind: change.kind, platform: change.platform, title: change.title, artist: change.artist,
                      artworkURL: change.artworkURL.flatMap(URL.init(string:)), confidence: change.confidence, reason: change.reason)
        }
        var record = RunRecord(
            id: log.id, seamId: pair.id, seamName: activityName(of: pair), direction: pair.syncDirection,
            date: log.startedAt ?? log.timestamp, trigger: log.trigger ?? SyncTrigger(log.action), result: log.result,
            duration: log.duration, failed: log.tracksFailed, undoneAt: log.undoneAt, undoOfRunId: log.undoOfRunId,
            changes: changes
        )
        if changes.isEmpty, log.trigger == nil { record.legacyAdded = log.tracksAdded }
        return record
    }
}

#if DEBUG
extension PreviewSeamRepository: ActivityRepository {
    func runs() async throws -> [RunRecord] { PreviewFixtures.runs }
    func run(_ id: UUID) async throws -> RunRecord? { PreviewFixtures.runs.first { $0.id == id } }
    func newTracks() async throws -> [NewTrack] { seenAll ? [] : PreviewFixtures.newTracks }
    func markAllSeen() async throws { seenAll = true }
}

extension PreviewFixtures {
    private static func change(_ title: String, _ artist: String, on platform: Platform = .appleMusic,
                               confidence: Int = 100, reason: MatchReason = .isrc) -> RunChange {
        RunChange(kind: .add, platform: platform, title: title, artist: artist, artworkURL: nil, confidence: confidence, reason: reason)
    }

    private static func record(_ seam: SeamSummary, minutesAgo: Double, trigger: SyncTrigger, changes: [RunChange],
                               duration: TimeInterval = 6) -> RunRecord {
        RunRecord(id: UUID(), seamId: seam.id, seamName: seam.name, direction: seam.direction,
                  date: Date().addingTimeInterval(-minutesAgo * 60), trigger: trigger, result: .success, duration: duration,
                  failed: 0, undoneAt: nil, undoOfRunId: nil, changes: changes)
    }

    /// The storyboard's Activity: three runs today, quieter days before.
    static let runs: [RunRecord] = {
        let today = Calendar.current.startOfDay(for: Date())
        let minutesToday = Date().timeIntervalSince(today) / 60
        func at(_ hour: Double) -> Double { max(1, minutesToday - hour * 60) }
        var runs = [
            record(lateNightDrive, minutesAgo: at(14.5), trigger: .monitor, changes: [
                change("Nightcall", "Kavinsky"), change("A Real Hero", "College, Electric Youth"),
                change("Tick of the Clock", "Chromatics", confidence: 97, reason: .titleArtistDuration),
                change("Under Your Spell", "Desire")
            ]),
            record(gardenSundays, minutesAgo: at(11), trigger: .manual, changes: [
                change("Towers", "Bon Iver", on: .spotify), change("Re: Stacks", "Bon Iver", on: .spotify)
            ]),
            record(lateNightDrive, minutesAgo: at(10.5), trigger: .monitor, changes: []),
            record(lateNightDrive, minutesAgo: at(10), trigger: .monitor, changes: []),
            record(runClub, minutesAgo: at(9.8), trigger: .firstSync,
                   changes: (0..<35).map { change("Track \($0)", "Artist") }, duration: 74)
        ]
        let perDay = [28, 40, 12, 51, 37, 0]
        for (day, count) in perDay.enumerated() where count > 0 {
            runs.append(record(gardenSundays, minutesAgo: minutesToday + Double(day) * 24 * 60 + 600, trigger: .monitor,
                               changes: (0..<count).map { change("Earlier \($0)", "Artist") }))
        }
        return runs
    }()

    static let newTracks: [NewTrack] = {
        func new(_ title: String, _ artist: String, _ seam: SeamSummary, landedOn: Platform, hoursAgo: Double) -> NewTrack {
            NewTrack(id: UUID(), seamId: seam.id, seamName: seam.name, direction: seam.direction, title: title, artist: artist,
                     artworkURL: nil, landedOn: landedOn, date: Date().addingTimeInterval(-hoursAgo * 3600))
        }
        return [
            new("Towers", "Bon Iver", gardenSundays, landedOn: .spotify, hoursAgo: 2),
            new("Re: Stacks", "Bon Iver", gardenSundays, landedOn: .spotify, hoursAgo: 2),
            new("Nightcall", "Kavinsky", lateNightDrive, landedOn: .appleMusic, hoursAgo: 5),
            new("A Real Hero", "College, Electric Youth", lateNightDrive, landedOn: .appleMusic, hoursAgo: 5),
            new("Tick of the Clock", "Chromatics", lateNightDrive, landedOn: .appleMusic, hoursAgo: 5),
            new("Under Your Spell", "Desire", lateNightDrive, landedOn: .appleMusic, hoursAgo: 5)
        ]
    }()
}
#endif
