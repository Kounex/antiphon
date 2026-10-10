import Foundation

/// What happens to a proposed match, decided by its confidence.
enum ConfidenceBand: Sendable, Equatable {
    /// At or above the auto-add threshold: added without asking.
    case automatic
    /// Between the review floor and the threshold: waits in the review queue.
    case review
    /// Below the review floor: never added, only offered as an alternative.
    case alternative
}

/// Maps a 0–100 match confidence to a `ConfidenceBand`.
///
/// Only the automatic boundary is adjustable (Settings › Matching). The review
/// floor is fixed at 60, matching the fuzzy-search acceptance score
/// `TrackMatcher` has always used.
struct ConfidencePolicy: Sendable, Equatable {
    static let reviewFloor = 60
    static let defaultAutoAddThreshold = 90

    let autoAddThreshold: Int

    init(autoAddThreshold: Int = ConfidencePolicy.defaultAutoAddThreshold) {
        self.autoAddThreshold = min(100, max(Self.reviewFloor, autoAddThreshold))
    }

    func band(for confidence: Int) -> ConfidenceBand {
        if confidence >= autoAddThreshold { return .automatic }
        if confidence >= Self.reviewFloor { return .review }
        return .alternative
    }
}
