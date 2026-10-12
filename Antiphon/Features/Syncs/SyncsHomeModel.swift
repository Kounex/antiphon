import AntiphonDesign
import Foundation
import Observation

/// The Syncs tab: one hero number, whatever needs the person, then every seam.
@MainActor
@Observable
final class SyncsHomeModel {
    enum Filter: Hashable { case all, watching, needsReview, paused }

    struct ReviewBanner: Equatable {
        let title: String
        let message: String
        let firstSeamId: UUID
    }

    private(set) var seams: [SeamSummary] = []
    private(set) var isLoaded = false
    var filter: Filter = .all

    private let repository: SeamRepository
    private let accounts: AccountsService
    /// What opening the app is checking, and what it found.
    private let checks: SeamChecks
    /// Checks every seam now, even ones checked in the last few minutes.
    private let checkNow: @MainActor () async -> Void
    private let now: () -> Date

    init(seams: SeamRepository, accounts: AccountsService, checks: SeamChecks = .shared,
         checkNow: @escaping @MainActor () async -> Void = {}, now: @escaping () -> Date = Date.init) {
        self.repository = seams
        self.accounts = accounts
        self.checks = checks
        self.checkNow = checkNow
        self.now = now
    }

    func load() async {
        seams = (try? await repository.seams()) ?? seams
        isLoaded = true
    }

    /// Pull to refresh: the store, then a check of every seam. The spinner
    /// stays until the checks are done; the cards say "checking now" meanwhile.
    func refresh() async {
        await load()
        await checkNow()
    }

    // MARK: - Hero

    var tracksInSync: Int { seams.reduce(0) { $0 + $1.counts.synced } }
    var watchingCount: Int { seams.filter(isWatching).count }

    /// "across 9 seams · checked 2 min ago"
    var heroDetail: String {
        var parts = ["across \(PlanCopy.count(seams.count, "seam"))"]
        if let latest = seams.compactMap(checkedAt).max() {
            parts.append("checked \(RelativeTime.text(since: latest, now: now()))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Filters

    var chips: [ChipBar<Filter>.Chip] {
        [
            .init(.all, "All", count: seams.count),
            .init(.watching, "Watching", count: watchingCount),
            .init(.needsReview, "Needs review", count: seams.filter { $0.counts.review > 0 }.count),
            .init(.paused, "Paused", count: seams.filter(\.isPaused).count)
        ]
    }

    var visibleSeams: [SeamSummary] {
        switch filter {
        case .all: seams
        case .watching: seams.filter(isWatching)
        case .needsReview: seams.filter { $0.counts.review > 0 }
        case .paused: seams.filter(\.isPaused)
        }
    }

    // MARK: - Banner

    var reviewBanner: ReviewBanner? {
        let waiting = seams.filter { $0.counts.review > 0 }
        guard let first = waiting.first else { return nil }
        let total = waiting.reduce(0) { $0 + $1.counts.review }
        let names = waiting.prefix(2).map(\.name)
        let list = names.count == 2 ? "\(names[0]) and \(names[1])" : names[0]
        let more = waiting.count > 2 ? " and \(waiting.count - 2) more" : ""
        return ReviewBanner(
            title: "\(PlanCopy.count(total, "track")) need\(total == 1 ? "s" : "") your call",
            message: "Close matches in \(list)\(more). Nothing was added yet.",
            firstSeamId: first.id
        )
    }

    // MARK: - Cards

    func subtitle(for seam: SeamSummary) -> String {
        var parts = [seam.directionText]
        if seam.isPaused {
            parts.append("paused")
        } else if isChecking(seam) {
            parts.append("checking now")
        } else if let checked = checkedAt(seam) {
            if let waiting = look(for: seam)?.waiting, waiting > 0 {
                parts.append("\(PlanCopy.count(waiting, "change")) waiting")
            }
            parts.append("checked \(RelativeTime.text(since: checked, now: now()))")
        } else {
            parts.append("not synced yet")
        }
        return parts.joined(separator: " · ")
    }

    func isChecking(_ seam: SeamSummary) -> Bool { checks.checking.contains(seam.id) }

    /// What reading an unwatched seam found, unless a sync came after it.
    private func look(for seam: SeamSummary) -> SeamChecks.Look? {
        guard let look = checks.looks[seam.id], look.at > (seam.lastCheckedAt ?? .distantPast) else { return nil }
        return look
    }

    private func checkedAt(_ seam: SeamSummary) -> Date? {
        [seam.lastCheckedAt, look(for: seam)?.at].compactMap { $0 }.max()
    }

    /// The failed pill's label, if something broke.
    func failure(for seam: SeamSummary) -> String? {
        if !accounts.isSpotifyConnected { return "Sign in" }
        return seam.lastResult == .failed ? "Failed" : nil
    }

    // MARK: - Actions

    func setPaused(_ paused: Bool, seamId: UUID) async {
        guard var rules = try? await repository.rules(for: seamId) else { return }
        rules.isPaused = paused
        try? await repository.update(rules, for: seamId)
        await load()
    }

    func unlink(_ seamId: UUID) async {
        try? await repository.unlink(seamId)
        await load()
    }

    private func isWatching(_ seam: SeamSummary) -> Bool { seam.isMonitored && !seam.isPaused }
}
