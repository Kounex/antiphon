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
    /// The one seam syncing, whose live sheet a tap reopens; `nil` for
    /// several, where a tap lists them.
    var seamId: UUID? = nil
}

enum RunningSyncSummary {
    /// One line for the accessory: the playlist and its progress, or the
    /// combined count when several seams sync at once.
    static func make(progress: [UUID: SyncProgress], seams: [SeamSummary]) -> RunningSync? {
        guard !progress.isEmpty else { return nil }
        let byId = Dictionary(seams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        if progress.count == 1, let (id, p) = progress.first {
            let one = row(id, p, seam: byId[id])
            return RunningSync(title: "Syncing \(one.title)", detail: one.detail, done: one.done, total: one.total,
                               seed: one.seed, seamId: id)
        }

        let done = progress.values.reduce(0) { $0 + $1.completedTracks + $1.failedTracks }
        let total = progress.values.reduce(0) { $0 + $1.totalTracks }
        return RunningSync(title: "Syncing \(progress.count) playlists", detail: "\(done) of \(total)", done: done, total: total, seed: "several")
    }

    /// Several at once: one row per seam for the list the accessory opens,
    /// titled by the seam's name.
    static func rows(progress: [UUID: SyncProgress], seams: [SeamSummary]) -> [RunningSync] {
        let byId = Dictionary(seams.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return progress.map { row($0.key, $0.value, seam: byId[$0.key]) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func row(_ id: UUID, _ p: SyncProgress, seam: SeamSummary?) -> RunningSync {
        let name = seam?.name ?? "playlist"
        let done = p.completedTracks + p.failedTracks
        let detail: String
        switch p.phase {
        case .matching:
            detail = [ "\(done) of \(p.totalTracks)", seam?.directionText ].compactMap { $0 }.joined(separator: " · ")
        case .adding(let platformName):
            detail = "Adding \(done) of \(p.totalTracks) to \(platformName)"
        }
        return RunningSync(title: name, detail: detail, done: done, total: p.totalTracks, seed: name, seamId: id)
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
    private(set) var reviewCount = 0
    private(set) var seams: [SeamSummary] = []

    let seamRepository: SeamRepository
    let accounts: AccountsService
    let sync: SyncService
    let library: LibraryService
    let reviews: ReviewRepository
    let problems: ProblemsRepository
    let catalogSearch: CatalogSearchService
    let index: TrackIndex
    let availability: AvailabilityService
    let activity: ActivityRepository
    let settings: SettingsStore
    let appleMusicAccount: AppleMusicAccountReader
    /// Activity's navigation.
    var activityPath: [ActivityRoute] = []
    @ObservationIgnored private(set) lazy var activityModel = ActivityModel(activity: activity)
    /// Library's navigation.
    var libraryPath: [LibraryRoute] = []
    /// A playlist picked in Library to start a seam from.
    var newSeamSource: LibraryPlaylist?
    /// Shared by Library and Search, so playlists load once.
    @ObservationIgnored private(set) lazy var libraryModel = LibraryModel(library: library, seams: seamRepository)
    @ObservationIgnored private(set) lazy var searchModel = SearchModel(index: index, library: libraryModel, preferences: .shared)
    /// The seam whose preview → sync flow is open.
    var syncFlowSeamId: UUID?
    /// The list of syncs running at once, opened from the accessory.
    var showsRunningSyncs = false
    /// A seam picked in that list, whose live sheet opens once the list has closed.
    var pendingSyncFlowSeam: UUID?
    /// The open review queue: one seam, or every seam.
    var reviewTarget: ReviewTarget?
    /// The open two-way removal question.
    var openConflict: ConflictPresentation?
    /// A seam whose removal questions open once the sync sheet has closed.
    var pendingConflictSeam: UUID?
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
         reviews: ReviewRepository, problems: ProblemsRepository, catalogSearch: CatalogSearchService,
         index: TrackIndex, availability: AvailabilityService, activity: ActivityRepository,
         settings: SettingsStore, appleMusicAccount: AppleMusicAccountReader) {
        self.index = index
        self.activity = activity
        self.settings = settings
        self.appleMusicAccount = appleMusicAccount
        self.availability = availability
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

    /// Opens the seam's first removal question, with the rest as "the others".
    func openFirstConflict(seamId: UUID) async {
        guard let all = try? await reviews.conflicts(seamId: seamId), let first = all.first else { return }
        openConflict = ConflictPresentation(item: first, others: Array(all.dropFirst()))
    }

    func reviewItem(rowId: UUID, seamId: UUID) async -> ReviewItem? {
        try? await reviews.reviewItems(seamId: seamId).first { $0.id == rowId }
    }

    func makeSyncFlow(seamId: UUID) -> SyncFlowModel {
        let isFirst = seams.first { $0.id == seamId }.map { $0.lastCheckedAt == nil } ?? true
        return SyncFlowModel(seamId: seamId, isFirstSync: isFirst, sync: sync, seams: seamRepository)
    }

    func makeNewSeam() -> NewSeamModel {
        let model = NewSeamModel(library: library, seams: seamRepository, preferences: .shared)
        if let source = newSeamSource { model.preselect(source) }
        return model
    }

    func makeSettings() -> SettingsModel {
        SettingsModel(store: settings, accounts: accounts, appleMusic: appleMusicAccount)
    }

    func makeRunDetail(_ runId: UUID) -> RunDetailModel {
        RunDetailModel(runId: runId, activity: activity, sync: sync)
    }

    func makePlaylistDetail(_ playlist: LibraryPlaylist) -> PlaylistDetailModel {
        PlaylistDetailModel(playlist: playlist, library: library, availability: availability)
    }

    /// "Stitch to …": the New seam flow, starting at this playlist's twin.
    func startSeam(from playlist: LibraryPlaylist) {
        newSeamSource = playlist
        showsNewSeam = true
    }

    /// A tapped widget: its seam, or New tracks, in place of any open sheet.
    func open(_ link: WidgetLink) {
        showsSettings = false
        showsNewSeam = false
        reviewTarget = nil
        openConflict = nil
        syncFlowSeamId = nil
        switch link {
        case .seam(let id):
            openSeamDetail(id)
        case .newTracks:
            selectedTab = .activity
            activityPath = []
            activityModel.tab = .newTracks
        }
    }

    /// Opens a seam on the Syncs tab, from Library or Search.
    func openSeamDetail(_ seamId: UUID) {
        selectedTab = .syncs
        syncsPath = [.seam(seamId)]
    }

    var accountInitials: String? { AccountInitials.from(accounts.spotifyDisplayName) }

    func refresh() async {
        guard let seams = try? await seamRepository.seams() else { return }
        self.seams = seams
        reviewCount = seams.reduce(0) { $0 + $1.counts.review }
        let problemsModel = makeProblems()
        await problemsModel.load(seams: seams)
        problemCount = problemsModel.count
    }

    func runningSync(_ progress: [UUID: SyncProgress]) -> RunningSync? {
        RunningSyncSummary.make(progress: progress, seams: seams)
    }
}
