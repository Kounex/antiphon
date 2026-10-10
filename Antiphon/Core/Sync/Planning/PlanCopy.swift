import Foundation

/// Plain-language sentences that state what a plan will do, in exact numbers.
/// The worst case (removals) always comes first.
enum PlanCopy {

    static func headline(for plan: SyncPlan) -> String {
        let removals = plan.removalCount
        let adds = plan.automaticAddCount

        if removals == 0 && adds == 0 {
            if plan.reviewCount > 0 {
                return "Nothing is removed. Nothing is added until you review \(count(plan.reviewCount, "close match", "close matches"))."
            }
            if !plan.conflicts.isEmpty {
                return "Nothing changes until you decide about \(count(plan.conflicts.count, "removed track"))."
            }
            return "Everything is already in sync."
        }

        let removalSentence = removals == 0 ? "Nothing is removed." : "Removes \(count(removals, "track"))."
        let addSentence: String
        switch adds {
        case 0: addSentence = "Nothing is added."
        case 1: addSentence = "1 track is added."
        default: addSentence = "\(adds) tracks are added."
        }
        return "\(removalSentence) \(addSentence)"
    }

    /// "Adds 12 tracks to Late Night Drive on Apple Music. Removes nothing."
    static func sideSentence(for side: SyncPlan.Side, playlistName: String) -> String {
        let adds = side.automaticAdds.count
        let removals = side.removals.filter { !$0.isGuided }.count
        let addPart = adds == 0
            ? "Adds nothing to \(playlistName) on \(side.platform.rawValue)."
            : "Adds \(count(adds, "track")) to \(playlistName) on \(side.platform.rawValue)."
        let removePart = removals == 0 ? "Removes nothing." : "Removes \(count(removals, "track"))."
        return "\(addPart) \(removePart)"
    }

    /// Tracks the planner couldn't look up this time.
    static func uncheckedNote(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(Self.count(count, "track")) couldn't be checked right now. Antiphon checks \(count == 1 ? "it" : "them") on the next sync."
    }

    static func count(_ n: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(n) \(n == 1 ? singular : (plural ?? singular + "s"))"
    }
}
