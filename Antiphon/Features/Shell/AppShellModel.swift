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
    var showsNewSeam = false
    /// The Syncs tab's navigation, so other screens can open a seam.
    var syncsPath: [SyncsRoute] = []
    var searchText = ""
    private(set) var reviewCount = 0
    private(set) var seams: [SeamSummary] = []

    let seamRepository: SeamRepository
    let accounts: AccountsService
    let sync: SyncService
    let library: LibraryService
    let reviews: ReviewRepository
    let problems: ProblemsRepository
    let catalogSearch: CatalogSearchService
    /// The seam whose preview → sync flow is open.
    var syncFlowSeamId: UUID?
    /// The open review queue: one seam, or every seam.
    var reviewTarget: ReviewTarget?
    /// The open two-way removal question.
    var openConflict: ConflictPresentation?
    private(set) var problemCount = 0

    struct ReviewTarget: Identifiable, Hashable {
        let seamId: UUID?
        var id: String { seamId?.uuidString ?? "all" }
    }

    struct ConflictPresentation: Identifiable {
        let item: ConflictItem
        let others: [ConflictItem]
        var id: TrackKey { item.id }
    }

    init(seams: SeamRepository, accounts: AccountsService, sync: SyncService, library: LibraryService,
         reviews: ReviewRepository, problems: ProblemsRepository, catalogSearch: CatalogSearchService) {
        self.seamRepository = seams
        self.accounts = accounts
        self.sync = sync
        self.library = library
        self.reviews = reviews
        self.problems = problems
        self.catalogSearch = catalogSearch
    }

    func makeReviewQueue(_ target: ReviewTarget) -> ReviewQueueModel {
        ReviewQueueModel(seamId: target.seamId, reviews: reviews, sync: sync)
    }

    func makeMatchDetail(_ item: ReviewItem) -> MatchDetailModel {
        MatchDetailModel(item: item, search: catalogSearch)
    }

    func makeProblems() -> ProblemsModel {
        ProblemsModel(seams: seamRepository, problems: problems, accounts: accounts)
    }

    /// Opens the removal question for a row, with the seam's other removals.
    func openConflict(rowId: UUID, seamId: UUID) async {
        guard let all = try? await reviews.conflicts(seamId: seamId),
              let item = all.first(where: { $0.rowId == rowId }) else { return }
        openConflict = ConflictPresentation(item: item, others: all.filter { $0.rowId != rowId })
    }

    func reviewItem(rowId: UUID, seamId: UUID) async -> ReviewItem? {
        try? await reviews.reviewItems(seamId: seamId).first { $0.id == rowId }
    }

    func makeSyncFlow(seamId: UUID) -> SyncFlowModel {
        let isFirst = seams.first { $0.id == seamId }.map { $0.lastCheckedAt == nil } ?? true
        return SyncFlowModel(seamId: seamId, isFirstSync: isFirst, sync: sync, seams: seamRepository)
    }

    func makeNewSeam() -> NewSeamModel {
        let linked = Set(seams.flatMap { [$0.spotify.playlistId, $0.appleMusic.playlistId] })
        return NewSeamModel(library: library, seams: seamRepository, preferences: .shared, linkedPlaylistIds: linked)
    }

    var accountInitials: String? { AccountInitials.from(accounts.spotifyDisplayName) }

    func refresh() async {
        guard let seams = try? await seamRepository.seams() else { return }
        self.seams = seams
        reviewCount = seams.reduce(0) { $0 + $1.counts.review }
        let problemsModel = makeProblems()
        await problemsModel.load()
        problemCount = problemsModel.count
    }

    func runningSync(_ progress: [UUID: SyncProgress]) -> RunningSync? {
        RunningSyncSummary.make(progress: progress, seams: seams)
    }
}
