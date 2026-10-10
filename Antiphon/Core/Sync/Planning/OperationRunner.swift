import Foundation
import SwiftData

/// Writes to one platform's playlists. The live editor wraps the existing
/// clients; tests use a fake.
protocol PlaylistEditor: Sendable {
    /// Returns the tracks that landed, identified as the platform now knows them.
    /// Throws `PlaylistEditError.partial` when only some landed.
    func add(_ tracks: [CatalogTrack], to playlistId: String, on platform: Platform) async throws -> [CatalogTrack]
    func remove(_ tracks: [CatalogTrack], from playlistId: String, on platform: Platform) async throws
    func tracks(in playlistId: String, on platform: Platform) async throws -> [CatalogTrack]
}

enum PlaylistEditError: Error {
    case partial(landed: [CatalogTrack], underlying: any Error)
    case unsupported
}

/// Carries out decisions that don't need a full sync — conflict answers,
/// undo, review decisions — and logs each as a run with its changes.
actor OperationRunner {

    enum Failure: Error, Equatable {
        case pairNotFound
        case runNotFound
        case alreadyUndone
        case trackNotFound
    }

    enum ReviewDecision: Sendable {
        case accept(MatchCandidate)
        case skip
    }

    struct Outcome: Sendable {
        /// Writes that landed.
        var landed: [SyncOperation] = []
        /// Writes the person has to make themselves.
        var guided: [SyncOperation] = []
        /// Undo steps that no longer applied.
        var skipped: [SyncOperation] = []
        var runId: UUID?
    }

    private let modelContainer: ModelContainer
    private let editor: any PlaylistEditor
    private let capabilities: PlatformCapabilities

    init(modelContainer: ModelContainer, editor: some PlaylistEditor, capabilities: PlatformCapabilities = .current) {
        self.modelContainer = modelContainer
        self.editor = editor
        self.capabilities = capabilities
    }

    // MARK: - Conflicts

    func resolve(_ resolutions: [ConflictResolution], pairId: UUID) async throws -> Outcome {
        let context = ModelContext(modelContainer)
        let pair = try fetchPair(pairId, in: context)

        var outcome = Outcome()
        let operations = resolutions.flatMap(\.operations)
        outcome.guided = operations.filter(\.isGuided)
        outcome.landed = try await execute(operations.filter { !$0.isGuided }, pair: pair, context: context,
                                           trigger: .conflict, undoOf: nil, outcome: &outcome)

        for resolution in resolutions {
            let landedAll = resolution.operations.allSatisfy { $0.isGuided || outcome.landed.contains($0) }
            guard landedAll, let row = row(for: resolution.conflict.key, in: pair) else { continue }
            switch resolution.rowUpdate {
            case .forget:
                context.delete(row)
            case .restore:
                row.removalFlag = nil
                row.removalFlaggedAt = nil
                row.removalKeptAt = nil
                row.source = .both
                row.syncState = .synced
            case .keepDifference:
                row.removalKeptAt = Date()
            }
        }
        try context.save()
        return outcome
    }

    // MARK: - Undo

    func undoPreview(runId: UUID) async throws -> UndoPlan {
        let context = ModelContext(modelContainer)
        let run = try fetchRun(runId, in: context)
        return try await undoPlan(for: run)
    }

    func undo(runId: UUID) async throws -> Outcome {
        let context = ModelContext(modelContainer)
        let run = try fetchRun(runId, in: context)
        guard run.undoneAt == nil else { throw Failure.alreadyUndone }
        guard let pair = run.syncPair else { throw Failure.pairNotFound }

        let plan = try await undoPlan(for: run)
        var outcome = Outcome(guided: plan.guided, skipped: plan.skipped)
        outcome.landed = try await execute(plan.operations, pair: pair, context: context,
                                           trigger: .undo, undoOf: runId, outcome: &outcome)

        for operation in outcome.landed where operation.kind == .remove {
            // Keep the undone track from being re-added or asked about.
            guard let row = row(identifiedAs: operation.track, in: pair) else { continue }
            row.removalFlag = operation.platform == .spotify ? .removedFromSpotify : .removedFromAppleMusic
            row.removalFlaggedAt = Date()
            row.removalKeptAt = Date()
            if row.source == .both { row.source = operation.platform == .spotify ? .appleMusic : .spotify }
        }
        if !outcome.landed.isEmpty { run.undoneAt = Date() }
        try context.save()
        return outcome
    }

    // MARK: - Review

    func decide(_ decision: ReviewDecision, for key: TrackKey, pairId: UUID) async throws -> Outcome {
        let context = ModelContext(modelContainer)
        let pair = try fetchPair(pairId, in: context)
        guard let row = row(for: key, in: pair) else { throw Failure.trackNotFound }

        switch decision {
        case .skip:
            row.syncState = .skipped
            try context.save()
            return Outcome()

        case .accept(let candidate):
            let operation = SyncOperation(kind: .add, platform: key.platform.other, track: candidate.track)
            var outcome = Outcome()
            let landed = try await execute([operation], pair: pair, context: context,
                                           trigger: .review, undoOf: nil, outcome: &outcome)
            outcome.landed = landed
            if let added = landed.first?.track {
                if added.platform == .spotify { row.spotifyTrackUri = added.id } else { row.appleMusicTrackId = added.id }
                row.source = .both
                row.syncState = .synced
                row.unmatchedPlatform = nil
                row.matchConfidence = candidate.confidence
                row.matchReason = candidate.reason
                row.counterpartISRC = candidate.track.isrc
            }
            try context.save()
            return outcome
        }
    }

    // MARK: - Private

    /// Runs the writes, then logs whatever landed — also when a later write fails.
    private func execute(
        _ operations: [SyncOperation],
        pair: SyncPair,
        context: ModelContext,
        trigger: SyncTrigger,
        undoOf: UUID?,
        outcome: inout Outcome
    ) async throws -> [SyncOperation] {
        var landed: [SyncOperation] = []
        do {
            for group in grouped(operations) {
                landed += try await write(group, pair: pair)
            }
        } catch PlaylistEditError.partial(let tracks, let underlying) {
            landed += operationsFor(tracks, like: operations)
            outcome.runId = log(landed, pair: pair, context: context, trigger: trigger, undoOf: undoOf)
            try context.save()
            throw underlying
        } catch {
            if !landed.isEmpty {
                outcome.runId = log(landed, pair: pair, context: context, trigger: trigger, undoOf: undoOf)
                try context.save()
            }
            throw error
        }
        outcome.runId = log(landed, pair: pair, context: context, trigger: trigger, undoOf: undoOf)
        return landed
    }

    private func write(_ group: [SyncOperation], pair: SyncPair) async throws -> [SyncOperation] {
        guard let first = group.first else { return [] }
        let playlistId = first.platform == .spotify ? pair.spotifyPlaylistId : pair.appleMusicPlaylistId
        let tracks = group.map(\.track)
        switch first.kind {
        case .add:
            let added = try await editor.add(tracks, to: playlistId, on: first.platform)
            return added.map { SyncOperation(kind: .add, platform: first.platform, track: $0) }
        case .remove:
            try await editor.remove(tracks, from: playlistId, on: first.platform)
            return group
        case .move:
            throw PlaylistEditError.unsupported
        }
    }

    /// Consecutive operations of the same kind on the same platform, batched.
    private func grouped(_ operations: [SyncOperation]) -> [[SyncOperation]] {
        operations.reduce(into: [[SyncOperation]]()) { groups, op in
            if let last = groups.last?.last, last.platform == op.platform, last.kind == op.kind {
                groups[groups.count - 1].append(op)
            } else {
                groups.append([op])
            }
        }
    }

    private func operationsFor(_ tracks: [CatalogTrack], like operations: [SyncOperation]) -> [SyncOperation] {
        tracks.map { track in SyncOperation(kind: .add, platform: track.platform, track: track) }
    }

    @discardableResult
    private func log(_ landed: [SyncOperation], pair: SyncPair, context: ModelContext,
                     trigger: SyncTrigger, undoOf: UUID?) -> UUID? {
        guard !landed.isEmpty else { return nil }
        let adds = landed.filter { $0.kind == .add }.count
        let removes = landed.filter { $0.kind == .remove }.count
        let log = SyncLog(action: .manualSync, result: .success, tracksAdded: adds, tracksRemoved: removes)
        log.trigger = trigger
        log.startedAt = Date()
        log.duration = 0
        log.undoOfRunId = undoOf
        log.syncPair = pair
        context.insert(log)
        for (index, operation) in landed.enumerated() {
            let kind: ChangeKind = switch operation.kind {
            case .add: .add
            case .remove: .remove
            case .move: .move
            }
            let change = SyncChange(platform: operation.platform, kind: kind, track: operation.track)
            change.sequence = index
            change.run = log
            context.insert(change)
        }
        return log.id
    }

    private func undoPlan(for run: SyncLog) async throws -> UndoPlan {
        guard let pair = run.syncPair else { throw Failure.pairNotFound }
        let changes = run.orderedChanges.map {
            RecordedChange(
                kind: $0.kind, platform: $0.platform,
                track: CatalogTrack(platform: $0.platform, id: $0.platformTrackId, title: $0.title,
                                    artist: $0.artist, isrc: $0.isrc, artworkURL: $0.artworkURL),
                fromIndex: $0.fromIndex, toIndex: $0.toIndex
            )
        }
        var current: [Platform: [CatalogTrack]] = [:]
        for platform in Set(changes.map(\.platform)) {
            let playlistId = platform == .spotify ? pair.spotifyPlaylistId : pair.appleMusicPlaylistId
            current[platform] = try await editor.tracks(in: playlistId, on: platform)
        }
        return UndoPlanner.plan(for: changes, capabilities: capabilities, current: current)
    }

    private func fetchPair(_ id: UUID, in context: ModelContext) throws -> SyncPair {
        guard let pair = try context.fetch(FetchDescriptor<SyncPair>(predicate: #Predicate { $0.id == id })).first else {
            throw Failure.pairNotFound
        }
        return pair
    }

    private func fetchRun(_ id: UUID, in context: ModelContext) throws -> SyncLog {
        guard let run = try context.fetch(FetchDescriptor<SyncLog>(predicate: #Predicate { $0.id == id })).first else {
            throw Failure.runNotFound
        }
        return run
    }

    private func row(for key: TrackKey, in pair: SyncPair) -> CachedTrack? {
        pair.cachedTracks.first { row in
            key.platform == .spotify ? row.spotifyTrackUri == key.id : row.appleMusicTrackId == key.id
        }
    }

    private func row(identifiedAs track: CatalogTrack, in pair: SyncPair) -> CachedTrack? {
        row(for: TrackKey(track), in: pair) ?? pair.cachedTracks.first { row in
            guard let isrc = track.isrc?.lowercased() else { return false }
            return row.isrc.lowercased() == isrc || row.counterpartISRC?.lowercased() == isrc
        }
    }
}
