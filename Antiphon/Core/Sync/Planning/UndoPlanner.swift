import Foundation

/// A change as recorded in a run's log (`SyncChange`), as a value.
struct RecordedChange: Sendable, Equatable {
    let kind: ChangeKind
    let platform: Platform
    let track: CatalogTrack
    var fromIndex: Int? = nil
    var toIndex: Int? = nil
}

struct UndoPlan: Sendable, Equatable {
    /// Writes Antiphon will run, newest change first.
    let operations: [SyncOperation]
    /// Inverse changes the platform can't make itself.
    let guided: [SyncOperation]
    /// Changes that no longer apply (e.g. the track was already removed by hand).
    let skipped: [SyncOperation]
    /// One sentence stating exactly what undo reverts.
    let summary: String
    let guidedNote: String?
}

enum UndoPlanner {

    static func plan(
        for changes: [RecordedChange],
        capabilities: PlatformCapabilities,
        current: [Platform: [CatalogTrack]] = [:]
    ) -> UndoPlan {
        var operations: [SyncOperation] = []
        var guided: [SyncOperation] = []
        var skipped: [SyncOperation] = []

        for change in changes.reversed() {
            var inverse = SyncOperation(kind: inverseKind(of: change), platform: change.platform, track: change.track)
            if let live = current[change.platform], !stillApplies(inverse, in: live) {
                skipped.append(inverse)
                continue
            }
            if capabilities.isGuided(inverse.kind, on: change.platform) {
                inverse.isGuided = true
                guided.append(inverse)
            } else {
                operations.append(inverse)
            }
        }

        return UndoPlan(
            operations: operations,
            guided: guided,
            skipped: skipped,
            summary: summary(operations: operations, skipped: skipped.count),
            guidedNote: guidedNote(guided)
        )
    }

    // MARK: - Private

    private static func inverseKind(of change: RecordedChange) -> SyncOperation.Kind {
        switch change.kind {
        case .add: .remove
        case .remove: .add
        case .move: .move(from: change.toIndex ?? 0, to: change.fromIndex ?? 0)
        }
    }

    private static func stillApplies(_ operation: SyncOperation, in live: [CatalogTrack]) -> Bool {
        let present = live.contains { MatchFinder.isSameRecording(operation.track, $0) }
        switch operation.kind {
        case .add: return !present
        case .remove, .move: return present
        }
    }

    private static func summary(operations: [SyncOperation], skipped: Int) -> String {
        var clauses: [String] = []
        var mentioned = Set<Platform>()

        for platform in [Platform.spotify, .appleMusic] {
            let ops = operations.filter { $0.platform == platform }
            let removals = ops.filter { $0.kind == .remove }.count
            let restores = ops.filter { $0.kind == .add }.count
            let moves = ops.filter { if case .move = $0.kind { true } else { false } }.count

            if removals > 0 {
                clauses.append(removals == 1
                    ? "removes this track from \(platform.rawValue)"
                    : "removes these \(removals) tracks from \(platform.rawValue)")
                mentioned.insert(platform)
            }
            if restores > 0 {
                clauses.append(restores == 1
                    ? "puts this track back on \(platform.rawValue)"
                    : "puts these \(restores) tracks back on \(platform.rawValue)")
                mentioned.insert(platform)
            }
            if moves > 0 {
                let base = moves == 1 ? "puts the moved one back" : "puts the \(moves) moved tracks back"
                clauses.append(mentioned.contains(platform) ? base : "\(base) on \(platform.rawValue)")
                mentioned.insert(platform)
            }
        }

        var text: String
        switch clauses.count {
        case 0: text = "Nothing can be undone automatically."
        case 1: text = clauses[0] + "."
        default: text = clauses.dropLast().joined(separator: ", ") + " and " + clauses[clauses.count - 1] + "."
        }
        text = text.prefix(1).uppercased() + text.dropFirst()

        if skipped > 0 {
            text += skipped == 1
                ? " 1 change no longer applies and is skipped."
                : " \(skipped) changes no longer apply and are skipped."
        }
        return text
    }

    private static func guidedNote(_ guided: [SyncOperation]) -> String? {
        guard !guided.isEmpty else { return nil }
        return "Antiphon can't change Apple Music playlists itself. It lists the \(PlanCopy.count(guided.count, "change")) so you can revert them in the Music app."
    }
}
