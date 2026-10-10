import Foundation
import Synchronization
import Testing
@testable import Antiphon

/// Records decisions and resolutions instead of making them.
final class RecordingSyncService: SyncService, Sendable {
    enum Call: Equatable {
        case accept(TrackKey, String)
        case skip(TrackKey)
        case resolve([TrackKey], ConflictResolution.RowUpdate)
    }

    private let log = Mutex<[Call]>([])
    private let failing: Bool
    init(failing: Bool = false) { self.failing = failing }
    var calls: [Call] { log.withLock { $0 } }

    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome {
        if failing { throw URLError(.timedOut) }
        log.withLock {
            switch decision {
            case .accept(let candidate): $0.append(.accept(key, candidate.track.id))
            case .skip: $0.append(.skip(key))
            }
        }
        return OperationRunner.Outcome()
    }

    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome {
        log.withLock { $0.append(.resolve(resolutions.map(\.conflict.key), resolutions.first?.rowUpdate ?? .keepDifference)) }
        var outcome = OperationRunner.Outcome()
        outcome.guided = resolutions.flatMap(\.operations).filter(\.isGuided)
        return outcome
    }

    func preview(seamId: UUID, isFirstSync: Bool, progress: (@Sendable (Int, Int) async -> Void)?) async throws -> PlannedSync { fatalError() }
    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger, progress: SyncProgressCallback?) async -> SyncResult { fatalError() }
    func undoPreview(runId: UUID) async throws -> UndoPlan { fatalError() }
    func undo(runId: UUID) async throws -> OperationRunner.Outcome { fatalError() }
}

/// Fixed review items and conflicts.
struct FixedReviews: ReviewRepository {
    var items: [ReviewItem] = []
    var conflictItems: [ConflictItem] = []
    func reviewItems(seamId: UUID?) async throws -> [ReviewItem] { items.filter { seamId == nil || $0.seamId == seamId } }
    func conflicts(seamId: UUID?) async throws -> [ConflictItem] { conflictItems.filter { seamId == nil || $0.seamId == seamId } }
}

@Suite("Review models")
@MainActor
struct ReviewModelsTests {

    private let seam = UUID()

    private func item(_ title: String, candidateTitle: String, confidence: Int = 86, seconds: Int = 243, explicit: Bool? = nil) -> ReviewItem {
        let source = CatalogTrack(platform: .spotify, id: "spotify:track:\(title)", title: title, artist: "M83",
                                  durationMs: 243_000, isExplicit: false)
        let candidate = CatalogTrack(platform: .appleMusic, id: "am-\(title)", title: candidateTitle, artist: "M83",
                                     durationMs: seconds * 1000, isExplicit: explicit)
        return ReviewItem(id: UUID(), seamId: seam, seamName: "Late Night Drive", key: TrackKey(source), source: source,
                          candidates: [MatchCandidate(track: candidate, confidence: confidence, reason: .versionDifference)])
    }

    // MARK: - Queue

    @Test("The queue counts its position and advances on each decision")
    func queueProgress() async {
        let sync = RecordingSyncService()
        let a = item("Midnight City", candidateTitle: "Midnight City (Remaster)")
        let b = item("Pump It", candidateTitle: "Pump It (Radio Edit)")
        let model = ReviewQueueModel(seamId: nil, reviews: FixedReviews(items: [a, b]), sync: sync)
        await model.load()
        #expect(model.positionText == "1 of 2")
        #expect(model.current?.source.title == "Midnight City")

        await model.accept()
        #expect(sync.calls == [.accept(a.key, "am-Midnight City")])
        #expect(model.positionText == "2 of 2")
        #expect(model.progress == 0.5)

        await model.skip()
        #expect(sync.calls.last == .skip(b.key))
        #expect(model.isFinished)
        #expect(model.summary == "1 added, 1 skipped.")
    }

    @Test("Picking another version adds that one instead")
    func pickAnother() async {
        let sync = RecordingSyncService()
        let a = item("Midnight City", candidateTitle: "Midnight City (Remaster)")
        let model = ReviewQueueModel(seamId: nil, reviews: FixedReviews(items: [a]), sync: sync)
        await model.load()
        let other = MatchCandidate(track: CatalogTrack(platform: .appleMusic, id: "orig", title: "Midnight City", artist: "M83"),
                                   confidence: 99, reason: .manual)
        await model.accept(other)
        #expect(sync.calls == [.accept(a.key, "orig")])
    }

    @Test("A failed decision keeps the card and says why")
    func failure() async {
        let model = ReviewQueueModel(seamId: nil, reviews: FixedReviews(items: [item("A", candidateTitle: "A (Remaster)")]),
                                     sync: RecordingSyncService(failing: true))
        await model.load()
        await model.accept()
        #expect(model.positionText == "1 of 1")
        #expect(model.error == "Antiphon couldn't add the track. Check your connection and try again.")
    }

    // MARK: - Card copy

    @Test("The card explains the difference in plain words")
    func explanations() {
        #expect(ReviewCopy.explanation(item("Midnight City", candidateTitle: "Midnight City (Remaster)"))
                == "Same artist and title, but a remastered release.")
        #expect(ReviewCopy.explanation(item("Faint", candidateTitle: "Faint (Live)"))
                == "Same artist and title, but a live recording.")
        #expect(ReviewCopy.explanation(item("Pump It", candidateTitle: "Pump It (Radio Edit)"))
                == "Same artist and title, but a radio edit.")
        #expect(ReviewCopy.explanation(item("Clean", candidateTitle: "Clean", explicit: true))
                == "Same artist and title, but the explicit version.")
        #expect(ReviewCopy.explanation(item("Long", candidateTitle: "Long", seconds: 255))
                == "Same artist and title, but 12 s longer.")
        #expect(ReviewCopy.explanation(item("X", candidateTitle: "X"))
                == "Same artist and title, different release.")
    }

    @Test("The notification-style line names the version and confidence")
    func headlineLine() {
        #expect(ReviewCopy.detailLine(item("Midnight City", candidateTitle: "Midnight City (Remaster)"))
                == "Midnight City by M83. Apple Music only has Midnight City (Remaster) (86% match).")
    }

    // MARK: - Conflicts

    private func conflict(_ title: String, removedFrom: Platform = .appleMusic, canRemove: Bool = true) -> ConflictItem {
        let spotify = CatalogTrack(platform: .spotify, id: "spotify:track:\(title)", title: title, artist: "Bon Iver")
        var apple = spotify
        apple.platform = .appleMusic
        apple.id = "i.\(title)"
        let c = SyncPlan.Conflict(key: TrackKey(spotify), track: spotify, removedFrom: removedFrom,
                                  noticedAt: Date(timeIntervalSince1970: 1_800_000_000),
                                  remaining: removedFrom == .appleMusic ? spotify : apple,
                                  removed: removedFrom == .appleMusic ? apple : spotify)
        return ConflictItem(seamId: seam, seamName: "Garden Sundays", conflict: c, remainingPlaylistName: "Garden Sundays",
                            appleMusicCanRemove: canRemove)
    }

    @Test("Conflict defaults to removing on the other side and repeats it as a verb")
    func conflictDefaults() async {
        let model = ConflictModel(item: conflict("Holocene"), others: [], sync: RecordingSyncService())
        #expect(model.outcome == .removeOnOtherSide)
        #expect(model.buttonTitle == "Remove from Spotify")
        #expect(model.title == "Holocene was removed on Apple Music")
        model.outcome = .restore
        #expect(model.buttonTitle == "Put back on Apple Music")
    }

    @Test("'Do the same' applies the choice to the seam's other removals")
    func doTheSame() async {
        let sync = RecordingSyncService()
        let holocene = conflict("Holocene"), towers = conflict("Towers")
        let model = ConflictModel(item: holocene, others: [towers], sync: sync)
        #expect(model.sameForOthersText == "Do the same for 1 other removal")
        model.applyToOthers = true
        model.outcome = .keepDifference
        await model.confirm()
        #expect(sync.calls == [.resolve([holocene.conflict.key, towers.conflict.key], .keepDifference)])
        #expect(model.isDone)
    }

    @Test("Removing on Apple Music is guided when Antiphon can't edit that playlist")
    func guidedNote() async {
        let model = ConflictModel(item: conflict("Towers", removedFrom: .spotify, canRemove: false), others: [], sync: RecordingSyncService())
        #expect(model.buttonTitle == "Remove from Apple Music")
        #expect(model.guidedNote == "Antiphon can't remove tracks from this Apple Music playlist. Remove Towers in the Music app; Antiphon notices on the next sync.")
        model.outcome = .restore
        #expect(model.guidedNote == nil)
    }
}
