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
    private let now: () -> Date

    init(seams: SeamRepository, accounts: AccountsService, now: @escaping () -> Date = Date.init) {
        self.repository = seams
        self.accounts = accounts
        self.now = now
    }

    func load() async {
        seams = (try? await repository.seams()) ?? seams
        isLoaded = true
    }

    // MARK: - Hero

    var tracksInSync: Int { seams.reduce(0) { $0 + $1.counts.synced } }
    var watchingCount: Int { seams.filter(isWatching).count }

    /// "across 9 seams · checked 2 min ago"
    var heroDetail: String {
        var parts = ["across \(PlanCopy.count(seams.count, "seam"))"]
        if let latest = seams.compactMap(\.lastCheckedAt).max() {
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
        let freshness: String
        if seam.isPaused {
            freshness = "paused"
        } else if let checked = seam.lastCheckedAt {
            freshness = "checked \(RelativeTime.text(since: checked, now: now()))"
        } else {
            freshness = "not synced yet"
        }
        return "\(seam.directionText) · \(freshness)"
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
