import Foundation
import Observation

/// Close matches as a quick card stack: accept, skip, or pick another version.
@MainActor
@Observable
final class ReviewQueueModel {
    /// One card: a close match to confirm, or a two-way removal to answer.
    enum Entry: Identifiable {
        case match(ReviewItem)
        case conflict(ConflictItem)

        var id: String {
            switch self {
            case .match(let item): "match-\(item.id)"
            case .conflict(let item): "conflict-\(item.id.platform.rawValue)-\(item.id.id)"
            }
        }
    }

    private(set) var entries: [Entry] = []
    private(set) var index = 0
    private(set) var error: String?
    private(set) var isLoaded = false
    private(set) var added = 0
    private(set) var skipped = 0
    private(set) var answered = 0
    /// Removals the person still has to make in the Music app.
    private(set) var guidedLeft: [SyncOperation] = []

    /// `nil` reviews every seam.
    let seamId: UUID?
    private let reviews: ReviewRepository
    private let sync: SyncService

    init(seamId: UUID?, reviews: ReviewRepository, sync: SyncService) {
        self.seamId = seamId
        self.reviews = reviews
        self.sync = sync
    }

    /// Close matches first, then removals — the same things the seam's
    /// "Review" count promises.
    func load() async {
        let matches = (try? await reviews.reviewItems(seamId: seamId)) ?? []
        let conflicts = (try? await reviews.conflicts(seamId: seamId)) ?? []
        entries = matches.map(Entry.match) + conflicts.map(Entry.conflict)
        index = 0
        isLoaded = true
    }

    var currentEntry: Entry? { entries.indices.contains(index) ? entries[index] : nil }
    var current: ReviewItem? {
        if case .match(let item) = currentEntry { item } else { nil }
    }
    var isFinished: Bool { isLoaded && index >= entries.count }
    var positionText: String { "\(min(index + 1, max(entries.count, 1))) of \(entries.count)" }
    var progress: Double { entries.isEmpty ? 1 : Double(index) / Double(entries.count) }
    /// What's left behind the current card, for the stack.
    var upcomingCount: Int { max(0, entries.count - index - 1) }

    var summary: String {
        var parts: [String] = []
        if added > 0 { parts.append("\(added) added") }
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if answered > 0 { parts.append("\(answered) answered") }
        return parts.isEmpty ? "Nothing changed." : parts.joined(separator: ", ") + "."
    }

    /// Adds the best match, or `candidate` when the person picked another version.
    func accept(_ candidate: MatchCandidate? = nil) async {
        guard let item = current, let choice = candidate ?? item.best else { return }
        do {
            _ = try await sync.decide(.accept(choice), for: item.key, seamId: item.seamId)
            added += 1
            advance()
        } catch {
            self.error = "Antiphon couldn't add the track. Check your connection and try again."
        }
    }

    func skip() async {
        guard let item = current else { return }
        do {
            _ = try await sync.decide(.skip, for: item.key, seamId: item.seamId)
            skipped += 1
            advance()
        } catch {
            self.error = "Antiphon couldn't save that. Try again."
        }
    }

    func resolve(_ item: ConflictItem, as outcome: ConflictOutcome) async {
        let resolutions = ConflictResolver.resolveAll([item.conflict], as: outcome, appleMusicCanRemove: item.appleMusicCanRemove)
        do {
            let result = try await sync.resolve(resolutions, seamId: item.seamId)
            guidedLeft += result.guided
            answered += 1
            advance()
        } catch {
            self.error = "Antiphon couldn't change the playlist. Check your connection and try again."
        }
    }

    private func advance() {
        error = nil
        index += 1
    }
}

/// One-line explanations for a close match.
enum ReviewCopy {

    static func explanation(_ item: ReviewItem) -> String {
        guard let best = item.best else { return "No close version was found." }
        let source = VersionTag.parse(item.source.title).tags
        let candidate = VersionTag.parse(best.track.title).tags

        for tag in candidate.subtracting(source).sorted(by: priority) {
            return "Same artist and title, but \(phrase(tag))."
        }
        if source.contains(.live), !candidate.contains(.live) { return "Same artist and title, but the studio version." }
        if source.contains(.remaster), !candidate.contains(.remaster) { return "Same artist and title, but the original release." }

        if let a = item.source.isExplicit, let b = best.track.isExplicit, a != b {
            return "Same artist and title, but the \(b ? "explicit" : "clean") version."
        }
        if let a = item.source.durationMs, let b = best.track.durationMs, abs(a - b) > 2000 {
            let seconds = abs(a - b) / 1000
            return "Same artist and title, but \(seconds) s \(b > a ? "longer" : "shorter")."
        }
        return "Same artist and title, different release."
    }

    /// "Midnight City by M83. Apple Music only has Midnight City (Remaster) (86% match)."
    static func detailLine(_ item: ReviewItem) -> String {
        guard let best = item.best else { return "\(item.source.title) by \(item.source.artist)." }
        return "\(item.source.title) by \(item.source.artist). \(item.targetPlatform.rawValue) only has \(best.track.title) (\(best.confidence)% match)."
    }

    private static func phrase(_ tag: VersionTag) -> String {
        switch tag {
        case .remaster: "a remastered release"
        case .live: "a live recording"
        case .remix: "a remix"
        case .radioEdit: "a radio edit"
        case .acoustic: "an acoustic version"
        case .instrumental: "an instrumental"
        case .demo: "a demo"
        case .clean: "the clean version"
        }
    }

    private static func priority(_ a: VersionTag, _ b: VersionTag) -> Bool {
        rank(a) < rank(b)
    }

    private static func rank(_ tag: VersionTag) -> Int {
        switch tag {
        case .live: 0
        case .remix: 1
        case .remaster: 2
        case .radioEdit: 3
        case .acoustic: 4
        case .instrumental: 5
        case .demo: 6
        case .clean: 7
        }
    }
}

/// "Holocene was removed on Apple Music": three outcomes, one verb.
@MainActor
@Observable
final class ConflictModel {
    let item: ConflictItem
    let others: [ConflictItem]
    var outcome: ConflictOutcome = .removeOnOtherSide
    var applyToOthers = false
    private(set) var isWorking = false
    private(set) var isDone = false
    private(set) var error: String?
    /// Removals the person still has to make in the Music app.
    private(set) var guidedLeft: [SyncOperation] = []

    private let sync: SyncService

    init(item: ConflictItem, others: [ConflictItem], sync: SyncService) {
        self.item = item
        self.others = others
        self.sync = sync
    }

    var title: String { item.question }

    func subtitle(now: Date = Date()) -> String { item.noticedLine(now: now) }

    var buttonTitle: String { ConflictResolver.buttonTitle(for: item.conflict, outcome: outcome) }

    var sameForOthersText: String? {
        guard !others.isEmpty else { return nil }
        return "Do the same for \(PlanCopy.count(others.count, "other removal"))"
    }

    var guidedNote: String? { outcome == .removeOnOtherSide ? item.guidedRemovalNote : nil }

    func confirm() async {
        isWorking = true
        defer { isWorking = false }
        let conflicts = [item] + (applyToOthers ? others : [])
        let resolutions = ConflictResolver.resolveAll(conflicts.map(\.conflict), as: outcome,
                                                      appleMusicCanRemove: item.appleMusicCanRemove)
        do {
            let result = try await sync.resolve(resolutions, seamId: item.seamId)
            guidedLeft = result.guided
            isDone = true
        } catch {
            self.error = "Antiphon couldn't change the playlist. Check your connection and try again."
        }
    }
}

/// Copy shared by the conflict sheet and the removal card in the queue.
extension ConflictItem {
    var question: String { "\(conflict.track.title) was removed on \(conflict.removedFrom.rawValue)" }

    func noticedLine(now: Date = Date()) -> String {
        let still = "It's still in \(remainingPlaylistName) on \(conflict.removedFrom.other.rawValue)."
        guard let noticed = conflict.noticedAt else { return still }
        return "Noticed \(RelativeTime.text(since: noticed, now: now)). \(still)"
    }

    /// Set when removing on the other side has to happen in the Music app.
    var guidedRemovalNote: String? {
        guard conflict.removedFrom.other == .appleMusic, !appleMusicCanRemove else { return nil }
        return "Antiphon can't remove tracks from this Apple Music playlist. Remove \(conflict.track.title) in the Music app; Antiphon notices on the next sync."
    }
}
