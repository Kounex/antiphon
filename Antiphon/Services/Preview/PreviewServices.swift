#if DEBUG
import Foundation

/// Synthetic data for SwiftUI previews and the DEBUG screenshot router.
/// Names follow the storyboard; nothing here is real user data.
enum PreviewFixtures {

    static let lateNightDrive = seam(
        "Late Night Drive", direction: .spotifyToApple, monitored: true,
        counts: SeamCounts(synced: 48, review: 3, missing: 1, total: 52), checkedMinutesAgo: 4
    )
    static let gardenSundays = seam(
        "Garden Sundays", direction: .bidirectional, monitored: true,
        counts: SeamCounts(synced: 117, review: 0, missing: 0, total: 117), checkedMinutesAgo: 30
    )
    static let runClub = seam(
        "Run Club", appleMusicName: "Running", direction: .spotifyToApple, monitored: true,
        counts: SeamCounts(synced: 31, review: 2, missing: 0, total: 52), checkedMinutesAgo: 1
    )
    static let vinylRips = seam(
        "Vinyl Rips", direction: .appleToSpotify, monitored: false, paused: true,
        counts: SeamCounts(synced: 80, review: 0, missing: 7, total: 87), checkedMinutesAgo: 60 * 26
    )

    static let seams = [lateNightDrive, gardenSundays, runClub, vinylRips]

    /// The App Store screenshots' fuller home (`shell/store`): seven seams.
    static let storeSeams = seams + [
        seam("Morning Coffee", direction: .bidirectional, monitored: true,
             counts: SeamCounts(synced: 64, review: 0, missing: 0, total: 64), checkedMinutesAgo: 12),
        seam("Road Trip Lisbon", direction: .spotifyToApple, monitored: true,
             counts: SeamCounts(synced: 109, review: 0, missing: 3, total: 112), checkedMinutesAgo: 18),
        seam("Sunday Brunch", direction: .appleToSpotify, monitored: true,
             counts: SeamCounts(synced: 41, review: 0, missing: 0, total: 41), checkedMinutesAgo: 45)
    ]

    static let lateNightDriveTracks: [SeamTrack] = [
        track("Nightcall", "Kavinsky", state: .synced, isNew: true),
        track("Midnight City", "M83", state: .review(confidence: 86, reason: .versionDifference)),
        track("Running Up That Hill", "Kate Bush", album: "Hounds of Love", state: .synced),
        track("Tokyo Drift (Live Session)", "Teriyaki Boyz", state: .missing("Not on Apple Music in Germany")),
        track("A Real Hero", "College, Electric Youth", state: .synced, isNew: true, origin: .appleMusic),
        track("Tick of the Clock", "Chromatics", state: .synced)
    ]

    /// The storyboard's first-sync preview: +33 on Apple Music (29 exact, 3 close, 1 unavailable), +6 on Spotify.
    static func firstSyncPlan(pairId: UUID = lateNightDrive.id) -> PlannedSync {
        func t(_ n: Int, _ p: Platform) -> CatalogTrack {
            CatalogTrack(platform: p, id: "\(p.rawValue)-\(n)", title: "Track \(n)", artist: "Artist \(n)")
        }
        var rows: [PlanRow] = []
        var outcomes: [TrackKey: MatchOutcome] = [:]
        func pending(_ n: Int, from p: Platform, confidence: Int?) {
            let row = PlanRow(source: t(n, p), counterpartId: nil, state: .pending, removalFlag: nil, removalKept: false, retryCount: 0)
            rows.append(row)
            outcomes[row.key] = MatchOutcome(
                best: confidence.map { MatchCandidate(track: t(n, p.other), confidence: $0, reason: $0 == 100 ? .isrc : .versionDifference) },
                alternatives: [], alreadyInTarget: false
            )
        }
        for n in 0..<29 { pending(n, from: .spotify, confidence: 100) }
        for n in 29..<32 { pending(n, from: .spotify, confidence: 84) }
        pending(32, from: .spotify, confidence: nil)
        for n in 100..<106 { pending(n, from: .appleMusic, confidence: 100) }
        for n in 200..<231 {
            rows.append(PlanRow(source: t(n, .spotify), counterpartId: "am-\(n)", state: .synced, removalFlag: nil, removalKept: false, retryCount: 0))
        }
        let plan = PlanBuilder.build(PlanInput(
            pairId: pairId, direction: .bidirectional, sourcePlatform: .spotify, removalPolicy: .ask,
            confidence: ConfidencePolicy(), rows: rows, outcomes: outcomes, appleMusicCanRemove: false
        ))
        return PlannedSync(plan: plan, fingerprint: PlaylistFingerprint(spotifyTracks: [], appleMusicTracks: []), sourcePlatform: .spotify)
    }

    // MARK: - Builders

    static func seam(
        _ name: String, appleMusicName: String? = nil, direction: SyncDirection, monitored: Bool, paused: Bool = false,
        counts: SeamCounts, checkedMinutesAgo: Double
    ) -> SeamSummary {
        SeamSummary(
            id: UUID(),
            spotify: SeamSide(platform: .spotify, playlistId: "Spotify-\(name)", name: name, artworkURL: nil),
            appleMusic: SeamSide(platform: .appleMusic, playlistId: "Apple Music-\(appleMusicName ?? name)", name: appleMusicName ?? name, artworkURL: nil),
            direction: direction, isMonitored: monitored, isPaused: paused, monitorIntervalMinutes: 15,
            lastCheckedAt: Date().addingTimeInterval(-checkedMinutesAgo * 60), lastResult: .success, counts: counts
        )
    }

    static func track(_ title: String, _ artist: String, album: String? = nil, state: TrackRowState, isNew: Bool = false,
                      origin: Platform = .spotify) -> SeamTrack {
        SeamTrack(id: UUID(), title: title, artist: artist, album: album, artworkURL: nil, state: state, isNew: isNew, origin: origin)
    }
}

extension PreviewFixtures {
    static let reviewItems: [ReviewItem] = {
        func item(_ title: String, _ artist: String, candidate: String, confidence: Int, seconds: Int, year: Int) -> ReviewItem {
            let source = CatalogTrack(platform: .spotify, id: "spotify:track:\(title)", title: title, artist: artist,
                                      album: "Original album", durationMs: 243_000, isrc: "PRV\(title.count)", isExplicit: false, releaseYear: 2011)
            let best = CatalogTrack(platform: .appleMusic, id: "am-\(title)", title: candidate, artist: artist,
                                    album: "\(candidate) (\(year))", durationMs: seconds * 1000, isrc: "PRV\(title.count)9",
                                    isExplicit: false, releaseYear: year)
            let live = CatalogTrack(platform: .appleMusic, id: "am-live-\(title)", title: "\(title) (Live)", artist: artist,
                                    album: "Live album", durationMs: 262_000, releaseYear: 2012)
            return ReviewItem(id: UUID(), seamId: lateNightDrive.id, seamName: lateNightDrive.name,
                              key: TrackKey(source), source: source,
                              candidates: [MatchCandidate(track: best, confidence: confidence, reason: .versionDifference),
                                           MatchCandidate(track: live, confidence: 41, reason: .versionDifference)])
        }
        return [
            item("Midnight City", "M83", candidate: "Midnight City (Remaster)", confidence: 86, seconds: 244, year: 2018),
            item("Pump It", "Black Eyed Peas", candidate: "Pump It (Radio Edit)", confidence: 84, seconds: 213, year: 2005),
            item("Lose Yourself", "Eminem", candidate: "Lose Yourself (Clean)", confidence: 76, seconds: 326, year: 2002)
        ]
    }()

    static let conflicts: [ConflictItem] = ["Holocene", "Towers"].map { title in
        let spotify = CatalogTrack(platform: .spotify, id: "spotify:track:\(title)", title: title, artist: "Bon Iver", album: "Bon Iver, Bon Iver")
        var apple = spotify
        apple.platform = .appleMusic
        apple.id = "i.\(title)"
        return ConflictItem(
            seamId: gardenSundays.id, seamName: gardenSundays.name,
            conflict: SyncPlan.Conflict(key: TrackKey(spotify), track: spotify, removedFrom: .appleMusic,
                                        noticedAt: Date().addingTimeInterval(-26 * 3600), remaining: spotify, removed: apple),
            remainingPlaylistName: gardenSundays.name, appleMusicCanRemove: false, rowId: UUID()
        )
    }
}

extension PreviewSeamRepository: ReviewRepository, ProblemsRepository {
    func reviewItems(seamId: UUID?) async throws -> [ReviewItem] {
        PreviewFixtures.reviewItems.filter { seamId == nil || $0.seamId == seamId }
    }
    func conflicts(seamId: UUID?) async throws -> [ConflictItem] {
        PreviewFixtures.conflicts.filter { seamId == nil || $0.seamId == seamId }
    }
    func problems() async throws -> [ProblemRecord] {
        guard showsProblems else { return [] }
        return [ProblemRecord(id: UUID(), kind: .playlistDeleted, platform: .appleMusic, seamId: PreviewFixtures.vinylRips.id,
                       message: "Vinyl Rips was deleted", firstSeenAt: Date().addingTimeInterval(-2 * 86_400), retryAt: nil),
         ProblemRecord(id: UUID(), kind: .rateLimited, platform: .appleMusic, seamId: nil, message: "Apple Music is busy",
                       firstSeenAt: Date(), retryAt: Date().addingTimeInterval(20 * 60))]
    }
}

/// In-memory `SeamRepository` for previews.
actor PreviewSeamRepository: SeamRepository {
    private var summaries: [SeamSummary]
    private var rulesById: [UUID: SeamRules] = [:]
    private let showsProblems: Bool
    /// Activity › New tracks "Mark all seen".
    var seenAll = false

    init(seams: [SeamSummary] = PreviewFixtures.seams, showsProblems: Bool = true) {
        summaries = seams
        self.showsProblems = showsProblems
    }

    func seams() async throws -> [SeamSummary] { summaries }

    /// `shell/store-live`: a seam's synced count while its sync runs.
    func setSynced(_ synced: Int, seamId: UUID) {
        guard let i = summaries.firstIndex(where: { $0.id == seamId }) else { return }
        let s = summaries[i]
        summaries[i] = SeamSummary(id: s.id, spotify: s.spotify, appleMusic: s.appleMusic, direction: s.direction,
                                   isMonitored: s.isMonitored, isPaused: s.isPaused,
                                   monitorIntervalMinutes: s.monitorIntervalMinutes, lastCheckedAt: s.lastCheckedAt,
                                   lastResult: s.lastResult,
                                   counts: SeamCounts(synced: synced, review: s.counts.review,
                                                      missing: s.counts.missing, total: s.counts.total))
    }
    func create(_ draft: SeamDraft) async throws -> UUID { PreviewFixtures.lateNightDrive.id }

    func detail(for id: UUID) async throws -> SeamDetail? {
        guard let summary = summaries.first(where: { $0.id == id }) else { return nil }
        // Enough rows to scroll under the toolbar.
        return SeamDetail(summary: summary, tracks: PreviewFixtures.lateNightDriveTracks + PreviewFixtures.lateNightDriveTracks.map {
            PreviewFixtures.track($0.title + " (Extended)", $0.artist, album: $0.album, state: $0.state, origin: $0.origin)
        })
    }

    func rules(for id: UUID) async throws -> SeamRules? {
        guard let summary = summaries.first(where: { $0.id == id }) else { return nil }
        return rulesById[id] ?? SeamRules(
            direction: summary.direction,
            removalPolicy: summary.direction == .bidirectional ? .ask : .keep,
            isMonitored: summary.isMonitored, monitorIntervalMinutes: nil,
            notifyNewTracks: false, isPaused: summary.isPaused
        )
    }

    func update(_ rules: SeamRules, for id: UUID) async throws { rulesById[id] = rules }
    func unlink(_ id: UUID) async throws { summaries.removeAll { $0.id == id } }
    func markViewed(_ id: UUID) async throws {}

    func pickTarget(seamId: UUID, rowId: UUID) async throws -> PickTarget? {
        guard let seam = summaries.first(where: { $0.id == seamId }),
              let track = (try await detail(for: seamId))?.tracks.first(where: { $0.id == rowId }) else { return nil }
        let source = CatalogTrack(platform: track.origin, id: "\(track.origin.rawValue)-\(track.title)", title: track.title,
                                  artist: track.artist, album: track.album, durationMs: 243_000)
        let current = CatalogTrack(platform: track.origin.other, id: "current-\(track.title)", title: track.title,
                                   artist: track.artist, album: "\(track.album ?? track.title) (Remaster)", durationMs: 244_000)
        return PickTarget(seam: seam, source: source, current: track.isPicked ? .yourPick(current) : .antiphonsPick(current))
    }

    func pickTarget(seamId: UUID, added: TrackKey, isrc: String?) async throws -> PickTarget? {
        guard let seam = summaries.first(where: { $0.id == seamId }) else { return nil }
        let item = PreviewFixtures.reviewItems[0]
        return PickTarget(seam: seam, source: item.source, current: .antiphonsPick(item.candidates[0].track), candidates: item.candidates)
    }
}

/// `SyncService` that never touches a platform.
struct PreviewSyncService: SyncService {
    func preview(seamId: UUID, isFirstSync: Bool, progress: (@Sendable (Int, Int) async -> Void)?) async throws -> PlannedSync {
        PreviewFixtures.firstSyncPlan(pairId: seamId)
    }

    func apply(_ planned: PlannedSync, approving: Set<TrackKey>, trigger: SyncTrigger, progress: SyncProgressCallback?) async -> SyncResult {
        let total = planned.plan.automaticAddCount
        for done in stride(from: 0, through: total, by: max(1, total / 10)) {
            await progress?(SyncProgress(totalTracks: total, completedTracks: done, failedTracks: 0))
        }
        return SyncResult(pairId: planned.plan.pairId, status: .success, tracksAdded: total)
    }

    func undoPreview(runId: UUID) async throws -> UndoPlan {
        let am = (1...4).map { RecordedChange(kind: .add, platform: .appleMusic, track: CatalogTrack(platform: .appleMusic, id: "\($0)", title: "T", artist: "A")) }
        return UndoPlanner.plan(for: am, capabilities: .full)
    }

    func undo(runId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func resolve(_ resolutions: [ConflictResolution], seamId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func decide(_ decision: OperationRunner.ReviewDecision, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func choose(_ candidate: MatchCandidate, for key: TrackKey, seamId: UUID) async throws -> OperationRunner.Outcome { OperationRunner.Outcome() }
    func keepPick(_ track: CatalogTrack, for key: TrackKey, seamId: UUID) async throws {}
    func forgetPick(for key: TrackKey, seamId: UUID) async throws {}
}
#endif

#if DEBUG
/// Storyboard-like libraries for previews.
struct PreviewLibraryService: LibraryService {
    static func playlist(_ name: String, _ platform: Platform, count: Int?, detail: String, blocked: String? = nil,
                         collaborative: Bool = false) -> LibraryPlaylist {
        LibraryPlaylist(platform: platform, id: "\(platform.rawValue)-\(name)", name: name, trackCount: count,
                        artworkURL: nil, detail: detail, isEditable: blocked == nil, blockedReason: blocked,
                        isOwn: blocked == nil, isCollaborative: collaborative)
    }

    static let spotify = [
        playlist("Workout Mix 2026", .spotify, count: 64, detail: "64 tracks · yours"),
        playlist("Discover Weekly", .spotify, count: 30, detail: "30 tracks · by Spotify", blocked: "Made by Spotify. Spotify doesn't let apps read these."),
        playlist("Road Trip Lisbon", .spotify, count: 112, detail: "112 tracks · collaborative", collaborative: true),
        playlist("Late Night Drive", .spotify, count: 52, detail: "52 tracks · yours"),
        playlist("Focus Flow", .spotify, count: 48, detail: "48 tracks · by Spotify", blocked: "Made by Spotify. Spotify doesn't let apps read these."),
        playlist("Garden Sundays", .spotify, count: 100, detail: "100 tracks · yours"),
        playlist("Run Club", .spotify, count: 50, detail: "50 tracks · yours"),
        playlist("Vinyl Rips", .spotify, count: 87, detail: "87 tracks · yours")
    ]
    static let appleMusic = [
        playlist("Gym Rotation", .appleMusic, count: 37, detail: "Apple Music"),
        playlist("Workout", .appleMusic, count: 20, detail: "Apple Music"),
        playlist("Vinyl Rips", .appleMusic, count: 87, detail: "Apple Music"),
        playlist("Garden Sundays", .appleMusic, count: 80, detail: "Apple Music"),
        playlist("Late Night Drive", .appleMusic, count: 47, detail: "Apple Music"),
        playlist("Running", .appleMusic, count: 37, detail: "Apple Music")
    ]

    func playlists(on platform: Platform) async throws -> [LibraryPlaylist] {
        platform == .spotify ? Self.spotify : Self.appleMusic
    }

    func tracks(of playlist: LibraryPlaylist) async throws -> [CatalogTrack] {
        func t(_ n: Int, _ p: Platform) -> CatalogTrack {
            // Unique titles: a repeated title would match across tracks.
            let title = n < Self.titles.count ? Self.titles[n] : "\(Self.titles[n % Self.titles.count]) No. \(n)"
            return CatalogTrack(platform: p, id: "\(p.rawValue)-\(n)", title: title, artist: Self.artists[n % Self.artists.count],
                                durationMs: 180_000 + n * 7_000, isrc: "PRV\(n)")
        }
        switch playlist.name {
        case "Road Trip Lisbon": return try await entries(of: playlist).map(\.track)
        case "Workout Mix 2026": return (0..<64).map { t($0, .spotify) }
        case "Gym Rotation": return (33..<64).map { t($0, .appleMusic) } + (100..<106).map { t($0, .appleMusic) }
        case "Workout": return (52..<64).map { t($0, .appleMusic) }
        // Onboarding's twins: 90%, 80%, 74% and 38% the same.
        case "Late Night Drive": return playlist.platform == .spotify ? (0..<52).map { t($0, .spotify) } : (5..<52).map { t($0, .appleMusic) }
        case "Garden Sundays": return playlist.platform == .spotify ? (0..<100).map { t($0, .spotify) } : (20..<100).map { t($0, .appleMusic) }
        case "Run Club": return (0..<50).map { t($0, .spotify) }
        case "Running": return (13..<50).map { t($0, .appleMusic) }
        case "Vinyl Rips": return playlist.platform == .spotify ? (0..<87).map { t($0, .spotify) } : (54..<87).map { t($0, .appleMusic) }
        default: return []
        }
    }

    func entries(of playlist: LibraryPlaylist) async throws -> [LibraryEntry] {
        guard playlist.name == "Road Trip Lisbon" else {
            return try await tracks(of: playlist).map { LibraryEntry(track: $0, addedBy: nil) }
        }
        let lisbon: [(String, String, AddedBy)] = [
            ("Fado Toninho", "Ana Moura", .collaborator), ("Lisboa, Anos 60", "Mariza", .you),
            ("Sodade (Live at Olympia)", "Cesária Évora", .collaborator), ("Canção do Mar", "Dulce Pontes", .you),
            ("Barco Negro", "Amália Rodrigues", .collaborator)
        ]
        return (0..<112).map { n in
            let (title, artist, by) = n < lisbon.count ? lisbon[n] : ("\(Self.titles[n % Self.titles.count]) No. \(n)", Self.artists[n % Self.artists.count], AddedBy.you)
            let user = by == .you ? "me" : (n % 2 == 0 ? "joana" : "rui")
            return LibraryEntry(track: CatalogTrack(platform: .spotify, id: "lisbon-\(n)", title: title, artist: artist,
                                                    durationMs: 247_000, isrc: "LIS\(n)"), addedBy: by, addedByUserId: user)
        }
    }

    func displayNames(for userIds: Set<String>) async -> [String: String] {
        ["joana": "Joana", "rui": "Rui"].filter { userIds.contains($0.key) }
    }

    static let unavailableTitles: Set<String> = ["Sodade (Live at Olympia)"]

    static let titles = ["Physical", "Blinding Lights", "Titanium", "Stronger", "Pump It", "Lose Yourself", "Can't Hold Us", "Eye of the Tiger"]
    static let artists = ["Dua Lipa", "The Weeknd", "David Guetta, Sia", "Kanye West", "Black Eyed Peas", "Eminem", "Macklemore", "Survivor"]
}
#endif
