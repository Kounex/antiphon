import Foundation
import Observation

/// What the sync accessory shows while syncs run.
struct RunningSync: Equatable, Sendable {
    let title: String
    let detail: String
    let done: Int
    let total: Int
    /// Seeds the placeholder cover.
    let seed: String
}

enum RunningSyncSummary {
    /// One line for the accessory: the playlist and its progress, or the
    /// combined count when several seams sync at once.
    static func make(progress: [UUID: SyncProgress], seams: [SeamSummary]) -> RunningSync? {
        guard !progress.isEmpty else { return nil }
        let byId = Dictionary(seams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if progress.count == 1, let (id, p) = progress.first {
            let seam = byId[id]
            let name = seam?.name ?? "playlist"
            let done = p.completedTracks + p.failedTracks
            let detail: String
            switch p.phase {
            case .matching:
                detail = [ "\(done) of \(p.totalTracks)", seam?.directionText ].compactMap { $0 }.joined(separator: " · ")
            case .adding(let platformName):
                detail = "Adding \(done) of \(p.totalTracks) to \(platformName)"
            }
            return RunningSync(title: "Syncing \(name)", detail: detail, done: done, total: p.totalTracks, seed: name)
        }

        let done = progress.values.reduce(0) { $0 + $1.completedTracks + $1.failedTracks }
        let total = progress.values.reduce(0) { $0 + $1.totalTracks }
        return RunningSync(title: "Syncing \(progress.count) playlists", detail: "\(done) of \(total)", done: done, total: total, seed: "several")
    }
}

enum AccountInitials {
    /// "Maya Klein" → "MK", "maya" → "M".
    static func from(_ name: String?) -> String? {
        let words = (name ?? "").split(whereSeparator: \.isWhitespace)
        guard let first = words.first?.first else { return nil }
        let last = words.count > 1 ? words.last?.first : nil
        return String([first] + (last.map { [$0] } ?? [])).uppercased()
    }
}

/// State for the tab shell: selection, the Syncs badge, the account button
/// and the Settings sheet.
@MainActor
@Observable
final class AppShellModel {
    enum Tab: Hashable { case syncs, library, activity, search }

    var selectedTab: Tab = .syncs
    var showsSettings = false
    var searchText = ""
    private(set) var reviewCount = 0
    private(set) var seams: [SeamSummary] = []

    private let seamRepository: SeamRepository
    private let accounts: AccountsService

    init(seams: SeamRepository, accounts: AccountsService) {
        self.seamRepository = seams
        self.accounts = accounts
    }

    var accountInitials: String? { AccountInitials.from(accounts.spotifyDisplayName) }

    func refresh() async {
        guard let seams = try? await seamRepository.seams() else { return }
        self.seams = seams
        reviewCount = seams.reduce(0) { $0 + $1.counts.review }
    }

    func runningSync(_ progress: [UUID: SyncProgress]) -> RunningSync? {
        RunningSyncSummary.make(progress: progress, seams: seams)
    }
}
