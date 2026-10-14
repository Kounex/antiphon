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
    /// Pull to refresh on Syncs: checks every seam now (`SeamChecks`). Set
    /// by the app; previews and tests check nothing.
    @ObservationIgnored var checkSeams: @MainActor () async -> Void = {}
    /// Every seam whose flow is loaded: running, just finished, or mid-preview.
    /// Both sync sheets show these, so "Hide" never loses the tracklist or
    /// progress: reopening shows exactly what was there before.
    private(set) var syncFlowModels: [UUID: SyncFlowModel] = [:]
    /// "Sync now": the preview sheet for this seam (the live glass sheet on top).
    var previewSeamId: UUID?
    /// The bar above the tabs: only the live glass sheet, over whatever is open.
    var showsLiveSheet = false
    /// Which sync the glass sheet shows, when several are running.
    var focusedLiveSeamId: UUID?
    /// The open review queue: one seam, or every seam.
    var reviewTarget: ReviewTarget?
    /// The open two-way removal question.
    var openConflict: ConflictPresentation?
    /// The song whose version picker is open (seam track list, New tracks).
    var picking: PickTarget?
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

    func makeVersionPicker(_ target: PickTarget) -> VersionPickerModel {
        VersionPickerModel(target: target, search: catalogSearch, preferences: AppPreferences.shared.versionPreferences)
    }

    /// Review's "Pick another version": nothing is in the playlist yet.
    func makeReviewPicker(_ item: ReviewItem) -> VersionPickerModel? {
        guard let seam = seams.first(where: { $0.id == item.seamId }) else { return nil }
        return makeVersionPicker(PickTarget(seam: seam, source: item.source, current: .notThere, candidates: item.candidates))
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

    /// A fresh flow for this seam, cached so any later reopen (the accessory,
    /// or this same call site) hands back this exact instance instead of
    /// starting over. Callers that show it inline (New seam) use this
    /// directly; "Sync now" elsewhere goes through `openSyncFlow`.
    @discardableResult
    func makeSyncFlow(seamId: UUID) -> SyncFlowModel {
        let isFirst = seams.first { $0.id == seamId }.map { $0.lastCheckedAt == nil } ?? true
        let model = SyncFlowModel(seamId: seamId, isFirstSync: isFirst, sync: sync, seams: seamRepository, search: catalogSearch)
        syncFlowModels[seamId] = model
        return model
    }

    /// "Sync now": the preview for this seam, from wherever the person is
    /// (never a tab or path change). A seam that's syncing shows its glass
    /// sheet instead of restarting; a finished one gets a fresh preview.
    func openSyncFlow(seamId: UUID) {
        if syncFlowModels[seamId]?.isSyncing == true {
            reopenRunningSyncs(ids: [], focus: seamId)
            return
        }
        makeSyncFlow(seamId: seamId)
        previewSeamId = seamId
    }

    /// The bar above the tabs: only the glass sheet with the live progress,
    /// over whatever is open, each sync keeping the content it had. A sync
    /// the shell doesn't know yet (started in the background) is followed,
    /// not previewed again.
    func reopenRunningSyncs(ids: [UUID], focus: UUID?) {
        for id in ids where syncFlowModels[id] == nil {
            makeSyncFlow(seamId: id).followRunningSync()
        }
        focusedLiveSeamId = focus.flatMap { liveSeamIds.contains($0) ? $0 : nil } ?? liveSeamIds.first
        showsLiveSheet = true
    }

    /// The glass sheet's syncs: running or finished (not previews), by seam
    /// name like the bar's own list, and stable for seams not loaded yet.
    var liveSeamIds: [UUID] {
        let names = Dictionary(seams.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        return syncFlowModels.filter { $0.value.keepsStateWhileHidden }.keys.sorted { a, b in
            let order = (names[a] ?? "").localizedStandardCompare(names[b] ?? "")
            return order == .orderedSame ? a.uuidString < b.uuidString : order == .orderedAscending
        }
    }

    /// "Review" on a sync's result: the sheets close, since neither can
    /// present the review queue over itself; other syncs stay for the bar.
    func openReview(fromSyncOf seamId: UUID) {
        closeSyncFlow(seamId: seamId)
        closeSheets()
        showsNewSeam = false
        selectedTab = .syncs
        syncsPath = [.seam(seamId)]
        reviewTarget = .init(seamId: seamId)
    }

    /// A sync left only removals to decide: the sheets close and their
    /// questions open, instead of waiting until the person closes them.
    func askAboutRemovals(fromSyncOf seamId: UUID) {
        pendingConflictSeam = seamId
        closeSyncFlow(seamId: seamId)
        closeSheets()
    }

    /// Closes the preview (Close, a swipe, or Hide on its glass sheet). A
    /// preview that never started is dropped; a running sync stays for the bar.
    func closePreview() {
        previewSeamId = nil
        // By flow, not by seam: a swipe clears `previewSeamId` before this runs.
        for (id, flow) in syncFlowModels where !flow.keepsStateWhileHidden {
            syncFlowModels[id] = nil
        }
    }

    /// Hide on the glass sheet: every sync keeps running and stays for the bar.
    func hideLiveSheet() {
        showsLiveSheet = false
    }

    private func closeSheets() {
        closePreview()
        hideLiveSheet()
    }

    /// This seam's flow is done being looked at (its result acknowledged):
    /// drop it. The glass sheet moves to another sync, or closes.
    func closeSyncFlow(seamId: UUID) {
        syncFlowModels[seamId] = nil
        if previewSeamId == seamId { previewSeamId = nil }
        if focusedLiveSeamId == seamId { focusedLiveSeamId = liveSeamIds.first }
        if liveSeamIds.isEmpty { showsLiveSheet = false }
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
        closeSheets()
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
