import Foundation
import Observation

/// Every failure says what broke, what it affects, and the one action that
/// fixes it. Temporary problems say when Antiphon retries.
@MainActor
@Observable
final class ProblemsModel {
    struct Card: Equatable {
        let title: String
        let message: String
    }

    struct Row: Identifiable, Equatable {
        let id: UUID
        let kind: ProblemKind
        let title: String
        let detail: String
        let seamId: UUID?
    }

    private(set) var signedOut: Card?
    private(set) var pausedSeams: [SeamSummary] = []
    private(set) var others: [Row] = []

    private let seams: SeamRepository
    private let problems: ProblemsRepository
    private let accounts: AccountsService
    private let now: () -> Date

    init(seams: SeamRepository, problems: ProblemsRepository, accounts: AccountsService, now: @escaping () -> Date = Date.init) {
        self.seams = seams
        self.problems = problems
        self.accounts = accounts
        self.now = now
    }

    var count: Int { (signedOut == nil ? 0 : 1) + others.count }

    func load() async {
        let all = (try? await seams.seams()) ?? []
        let records = (try? await problems.problems()) ?? []

        if !accounts.isSpotifyConnected {
            let watched = all.filter { $0.isMonitored && !$0.isPaused }
            signedOut = Card(
                title: "Spotify signed you out",
                message: "Monitoring is paused for \(Self.which(watched.count)) until you sign in again. Nothing was lost."
            )
            pausedSeams = watched
        } else {
            signedOut = nil
            pausedSeams = []
        }

        others = records
            .filter { !($0.kind == .signedOut && $0.platform == .spotify) }
            .map { record in
                Row(id: record.id, kind: record.kind, title: record.message, detail: detail(for: record), seamId: record.seamId)
            }
    }

    /// "all 3 watched seams", "your watched seam", "your seams".
    static func which(_ count: Int) -> String {
        switch count {
        case 0: "your seams"
        case 1: "your watched seam"
        default: "all \(count) watched seams"
        }
    }

    private func detail(for record: ProblemRecord) -> String {
        if let retry = record.retryAt {
            return "Antiphon will retry at \(retry.formatted(date: .omitted, time: .shortened))"
        }
        let platform = record.platform.map { "On \($0.rawValue), " } ?? ""
        return platform + RelativeTime.text(since: record.firstSeenAt, now: now())
    }
}
