import Foundation
import UserNotifications

/// A button on a question notification. Answers run in the background, the
/// same way the Review screen runs them, so they're in History and undoable.
enum QuestionAction: String, Sendable, CaseIterable {
    case skip, useMatch, removeToo, putBack, leaveAsIs

    /// Buttons that change a playlist need the phone unlocked.
    var writes: Bool {
        switch self {
        case .useMatch, .removeToo, .putBack: true
        case .skip, .leaveAsIs: false
        }
    }
}

/// The kinds of question notification, each with its buttons.
enum QuestionCategory: String, Sendable, CaseIterable {
    case closeMatch = "question.closeMatch"
    case closeMatchRemaster = "question.closeMatchRemaster"
    case removal = "question.removal"
    /// The copy that's left is in an Apple Music playlist Antiphon can't remove from (D1).
    case removalKeepOrRestore = "question.removalKeepOrRestore"

    struct Button: Equatable, Sendable {
        let action: QuestionAction
        let title: String
    }

    var actions: [Button] {
        switch self {
        case .closeMatch: [Button(action: .skip, title: "Skip"), Button(action: .useMatch, title: "Use this version")]
        case .closeMatchRemaster: [Button(action: .skip, title: "Skip"), Button(action: .useMatch, title: "Use remaster")]
        case .removal: [Button(action: .removeToo, title: "Remove it too"), Button(action: .putBack, title: "Put it back"),
                        Button(action: .leaveAsIs, title: "Leave as is")]
        case .removalKeepOrRestore: [Button(action: .putBack, title: "Put it back"), Button(action: .leaveAsIs, title: "Leave as is")]
        }
    }

    var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: rawValue,
            actions: actions.map { button in
                var options: UNNotificationActionOptions = button.action.writes ? [.authenticationRequired] : []
                if button.action == .removeToo { options.insert(.destructive) }
                return UNNotificationAction(identifier: button.action.rawValue, title: button.title, options: options)
            },
            intentIdentifiers: []
        )
    }
}

/// One question as a notification: the decision is its buttons.
struct QuestionNotice: Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let body: String
    let category: QuestionCategory
    /// Plain strings, so they survive the trip through the system.
    var userInfo: [String: String]

    /// One question per track and seam, so answering it in the app can
    /// remove its notification.
    static func id(seamId: UUID, key: TrackKey) -> String {
        "question-\(seamId.uuidString)-\(key.platform.rawValue)-\(key.id)"
    }

    init(_ item: ReviewItem) {
        id = Self.id(seamId: item.seamId, key: item.key)
        title = "Is this the same track?"
        subtitle = item.seamName
        body = ReviewCopy.detailLine(item)
        // "Use remaster" only when the offered version adds a remaster.
        let sourceTags = VersionTag.parse(item.source.title).tags
        let isRemaster = item.best.map { VersionTag.parse($0.track.title).tags.subtracting(sourceTags).contains(.remaster) } ?? false
        category = isRemaster ? .closeMatchRemaster : .closeMatch
        userInfo = ["seamId": item.seamId.uuidString, "rowId": item.id.uuidString]
    }

    init(_ item: ConflictItem) {
        id = Self.id(seamId: item.seamId, key: item.conflict.key)
        title = item.question
        subtitle = item.seamName
        let other = item.conflict.removedFrom.other
        let canRemove = other == .spotify || item.appleMusicCanRemove
        let still = "It's still in \(item.remainingPlaylistName) on \(other.rawValue)."
        body = canRemove ? "\(still) Remove it there too?" : "\(still) Antiphon can't remove it there; put it back or leave it?"
        category = canRemove ? .removal : .removalKeepOrRestore
        userInfo = ["seamId": item.seamId.uuidString, "keyPlatform": item.conflict.key.platform.rawValue,
                    "keyId": item.conflict.key.id]
    }
}

enum QuestionNotifications {
    enum Answer: Equatable, Sendable {
        case answered
        /// Answered in the app meanwhile, or the seam is gone: nothing to do.
        case gone
        /// The write didn't go through; the question is still waiting.
        case failed
    }

    /// Tells questions apart across runs: a close match by its row, a
    /// removal by its seam and track.
    static func identity(_ item: ConflictItem) -> String { QuestionNotice.id(seamId: item.seamId, key: item.conflict.key) }

    /// More than this many new questions in one run get the summary instead:
    /// a stack of notifications helps no one.
    static let limit = 3

    static func notices(review: [ReviewItem], conflicts: [ConflictItem]) -> [QuestionNotice] {
        guard review.count + conflicts.count <= limit else { return [] }
        return review.map(QuestionNotice.init) + conflicts.map(QuestionNotice.init)
    }

    /// Runs a tapped button.
    static func answer(_ action: QuestionAction, userInfo: [String: String],
                       review: some ReviewRepository, sync: some SyncService) async -> Answer {
        guard let seamId = userInfo["seamId"].flatMap(UUID.init(uuidString:)) else { return .gone }
        switch action {
        case .skip, .useMatch:
            guard let rowId = userInfo["rowId"].flatMap(UUID.init(uuidString:)),
                  let item = try? await review.reviewItems(seamId: seamId).first(where: { $0.id == rowId }) else { return .gone }
            let decision: OperationRunner.ReviewDecision
            if action == .skip {
                decision = .skip
            } else {
                guard let best = item.best else { return .gone }
                decision = .accept(best)
            }
            return (try? await sync.decide(decision, for: item.key, seamId: seamId)) != nil ? .answered : .failed

        case .removeToo, .putBack, .leaveAsIs:
            guard let platform = userInfo["keyPlatform"].flatMap(Platform.init(rawValue:)), let keyId = userInfo["keyId"] else { return .gone }
            let key = TrackKey(platform: platform, id: keyId)
            guard let item = try? await review.conflicts(seamId: seamId).first(where: { $0.conflict.key == key }) else { return .gone }
            let outcome: ConflictOutcome = switch action {
            case .removeToo: .removeOnOtherSide
            case .putBack: .restore
            default: .keepDifference
            }
            let resolution = ConflictResolver.resolve(item.conflict, as: outcome, appleMusicCanRemove: item.appleMusicCanRemove)
            return (try? await sync.resolve([resolution], seamId: seamId)) != nil ? .answered : .failed
        }
    }
}
