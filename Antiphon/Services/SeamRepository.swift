import Foundation
import SwiftData

/// One playlist in a seam.
struct SeamSide: Hashable, Sendable {
    let platform: Platform
    let playlistId: String
    let name: String
    let artworkURL: URL?
}

/// A seam at a glance, for sync cards and lists.
struct SeamSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    let spotify: SeamSide
    let appleMusic: SeamSide
    let direction: SyncDirection
    let isMonitored: Bool
    let isPaused: Bool
    /// Requested minutes between checks (seam's own or the app default).
    let monitorIntervalMinutes: Int
    let lastCheckedAt: Date?
    let lastResult: SyncResultStatus?
    let counts: SeamCounts
    /// The direction changed: the next sync rebuilds, after a preview.
    var needsRebuild = false

    /// The leading side: the source of a one-way seam, Spotify for two-way.
    var source: Platform { direction == .appleToSpotify ? .appleMusic : .spotify }
    var name: String { side(source).name }
    func side(_ platform: Platform) -> SeamSide { platform == .spotify ? spotify : appleMusic }
}

struct SeamTrack: Identifiable, Hashable, Sendable {
    let id: UUID
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let state: TrackRowState
    /// Added by Antiphon since the person last opened the seam.
    let isNew: Bool
    /// The side the track came from, shown as the source dot.
    var origin: Platform = .spotify
    /// The person picked the version on the other side.
    var isPicked = false
}

struct SeamDetail: Sendable {
    let summary: SeamSummary
    let tracks: [SeamTrack]
}

/// The rules a person edits on the Rules screen.
struct SeamRules: Equatable, Sendable {
    var direction: SyncDirection
    var removalPolicy: RemovalPolicy
    var isMonitored: Bool
    /// `nil` uses the app default; `0` is "Only when I ask".
    var monitorIntervalMinutes: Int?
    var notifyNewTracks: Bool
    var isPaused: Bool
    var placement: TrackPlacement = .sourceOrder
    /// Apple Music lets apps reorder only playlists they created (D1).
    var appleMusicCanReorder: Bool = false
}

/// A seam about to be created.
struct SeamDraft: Sendable {
    enum Target: Sendable {
        case existing(LibraryPlaylist)
        /// Created on the other platform during the first sync.
        case new(name: String)
    }

    let source: LibraryPlaylist
    let target: Target
    let direction: SyncDirection
    let removalPolicy: RemovalPolicy
    let isMonitored: Bool
    let monitorIntervalMinutes: Int?
}

/// Read and edit seams. Views talk to this, never to SwiftData.
protocol SeamRepository: Sendable {
    /// Links the two playlists. Nothing syncs until the first preview is approved.
    func create(_ draft: SeamDraft) async throws -> UUID
    func seams() async throws -> [SeamSummary]
    func detail(for id: UUID) async throws -> SeamDetail?
    func rules(for id: UUID) async throws -> SeamRules?
    func update(_ rules: SeamRules, for id: UUID) async throws
    /// Removes the seam from Antiphon. Both playlists stay exactly as they are.
    func unlink(_ id: UUID) async throws
    /// The person opened the seam; resets what counts as "New".
    func markViewed(_ id: UUID) async throws
    /// The version picker for one stored song.
    func pickTarget(seamId: UUID, rowId: UUID) async throws -> PickTarget?
    /// The same, found by the version Antiphon added (Activity › New tracks).
    func pickTarget(seamId: UUID, added: TrackKey, isrc: String?) async throws -> PickTarget?
}

/// `SeamRepository` over the shared SwiftData store.
actor SwiftDataSeamRepository: SeamRepository {
    private let modelContainer: ModelContainer
    var modelContainerForReview: ModelContainer { modelContainer }
    private let preferences: AppPreferences
    /// How far back "New" looks when a seam has never been opened.
    private let newWindow: TimeInterval = 7 * 24 * 3600

    init(modelContainer: ModelContainer, preferences: AppPreferences = .shared) {
        self.modelContainer = modelContainer
        self.preferences = preferences
    }

    func create(_ draft: SeamDraft) async throws -> UUID {
        let context = ModelContext(modelContainer)
        let source = draft.source
        let targetPlatform = source.platform.other
        let (targetId, targetName, targetArtwork): (String, String, URL?) = switch draft.target {
        case .existing(let playlist): (playlist.id, playlist.name, playlist.artworkURL)
        case .new(let name): ("pending-creation-\(UUID().uuidString)", name, nil)
        }
        let spotify = source.platform == .spotify ? (source.id, source.name, source.artworkURL) : (targetId, targetName, targetArtwork)
        let apple = targetPlatform == .appleMusic ? (targetId, targetName, targetArtwork) : (source.id, source.name, source.artworkURL)

        let pair = SyncPair(
            spotifyPlaylistId: spotify.0, spotifyPlaylistName: spotify.1,
            appleMusicPlaylistId: apple.0, appleMusicPlaylistName: apple.1,
            syncDirection: draft.direction
        )
        pair.spotifyImageURL = spotify.2?.absoluteString
        pair.appleMusicImageURL = apple.2?.absoluteString
        pair.removalPolicy = draft.removalPolicy
        pair.isMonitored = draft.isMonitored
        pair.monitorIntervalMinutes = draft.monitorIntervalMinutes
        context.insert(pair)
        try context.save()
        return pair.id
    }

    func seams() async throws -> [SeamSummary] {
        let context = ModelContext(modelContainer)
        let pairs = try context.fetch(FetchDescriptor<SyncPair>(sortBy: [SortDescriptor(\.createdAt)]))
        return pairs.map(summary)
    }

    func detail(for id: UUID) async throws -> SeamDetail? {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(id, in: context) else { return nil }

        let since = pair.lastViewedAt ?? Date().addingTimeInterval(-newWindow)
        let newIds = Set(pair.syncLogs
            .filter { $0.timestamp > since }
            .flatMap(\.changes)
            .filter { $0.kind == .add }
            .map(\.platformTrackId))
        let addedTo = Self.addedTo(pair)
        let leading = Self.leading(pair)
        let picked = Set(pair.pins.map(\.key))

        let tracks = pair.cachedTracks
            .filter { $0.removalFlag != .extraOnDestination }
            .sorted { $0.addedAt < $1.addedAt }
            .map { track in
                SeamTrack(
                    id: track.id, title: track.title, artist: track.artist, album: track.albumName,
                    artworkURL: track.artworkURL.flatMap(URL.init(string:)),
                    state: TrackRowState(track),
                    isNew: [track.spotifyTrackUri, track.appleMusicTrackId].contains { $0.map(newIds.contains) ?? false },
                    origin: Self.origin(of: track, addedTo: addedTo, leading: leading),
                    isPicked: Self.source(of: track, addedTo: addedTo, leading: leading).map { picked.contains(TrackKey($0)) } ?? false
                )
            }
        return SeamDetail(summary: summary(pair), tracks: tracks)
    }

    func rules(for id: UUID) async throws -> SeamRules? {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(id, in: context) else { return nil }
        return SeamRules(
            direction: pair.syncDirection,
            removalPolicy: pair.effectiveRemovalPolicy,
            isMonitored: pair.isMonitored,
            monitorIntervalMinutes: pair.monitorIntervalMinutes,
            notifyNewTracks: pair.notifyNewTracks,
            isPaused: pair.isPaused,
            placement: pair.effectivePlacement,
            appleMusicCanReorder: pair.appleMusicCreatedByAntiphon
        )
    }

    func update(_ rules: SeamRules, for id: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(id, in: context) else { return }
        if rules.direction != pair.syncDirection { pair.needsRebuild = true }
        pair.syncDirection = rules.direction
        pair.removalPolicy = rules.removalPolicy
        pair.isMonitored = rules.isMonitored
        pair.monitorIntervalMinutes = rules.monitorIntervalMinutes
        pair.notifyNewTracks = rules.notifyNewTracks
        pair.newTrackPlacement = rules.placement
        if rules.isPaused != pair.isPaused {
            pair.pausedAt = rules.isPaused ? Date() : nil
        }
        try context.save()
    }

    func unlink(_ id: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(id, in: context) else { return }
        context.delete(pair)
        try context.save()
    }

    func markViewed(_ id: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(id, in: context) else { return }
        pair.lastViewedAt = Date()
        try context.save()
    }

    // MARK: - Private

    /// Rows only on one side came from that side. Rows on both came from the
    /// other side of wherever Antiphon copied them, or else the leading side.
    static func origin(of track: CachedTrack, addedTo: [String: Platform], leading: Platform) -> Platform {
        switch track.source {
        case .spotify: return .spotify
        case .appleMusic: return .appleMusic
        case .both:
            for id in [track.spotifyTrackUri, track.appleMusicTrackId].compactMap({ $0 }) {
                if let platform = addedTo[id] { return platform.other }
            }
            return leading
        }
    }

    func pickTarget(seamId: UUID, rowId: UUID) async throws -> PickTarget? {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(seamId, in: context),
              let row = pair.cachedTracks.first(where: { $0.id == rowId }) else { return nil }
        return pickTarget(row, in: pair)
    }

    func pickTarget(seamId: UUID, added: TrackKey, isrc: String?) async throws -> PickTarget? {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(seamId, in: context) else { return nil }
        let byId = pair.cachedTracks.first { (added.platform == .spotify ? $0.spotifyTrackUri : $0.appleMusicTrackId) == added.id }
        // Apple Music lists an add under another ID later; the ISRC still finds it.
        let byISRC = isrc.map { $0.lowercased() }.flatMap { isrc in
            pair.cachedTracks.first { $0.counterpartISRC?.lowercased() == isrc || $0.isrc.lowercased() == isrc }
        }
        return (byId ?? byISRC).flatMap { pickTarget($0, in: pair) }
    }

    /// The song on the side it came from; the version goes to the other.
    private func pickTarget(_ row: CachedTrack, in pair: SyncPair) -> PickTarget? {
        guard let source = Self.source(of: row, addedTo: Self.addedTo(pair), leading: Self.leading(pair)) else { return nil }
        let target = source.platform.other
        let current: PickTarget.Current
        if let pick = pair.pinnedTracks[TrackKey(source)] {
            current = .yourPick(pick)
        } else if row.effectiveSyncState == .synced, let id = target == .spotify ? row.spotifyTrackUri : row.appleMusicTrackId {
            current = .antiphonsPick(CatalogTrack(platform: target, id: id, title: row.title, artist: row.artist,
                                                  album: row.counterpartAlbum, isrc: row.counterpartISRC))
        } else {
            current = .notThere
        }
        return PickTarget(seam: summary(pair), source: source, current: current, candidates: row.candidates)
    }

    private static func source(of row: CachedTrack, addedTo: [String: Platform], leading: Platform) -> CatalogTrack? {
        let origin = origin(of: row, addedTo: addedTo, leading: leading)
        guard let id = origin == .spotify ? row.spotifyTrackUri : row.appleMusicTrackId else { return nil }
        return CatalogTrack(platform: origin, id: id, title: row.title, artist: row.artist, album: row.albumName,
                            durationMs: row.durationMs, isrc: row.isrc.hasPrefix("local-") ? nil : row.isrc, artworkURL: row.artworkURL)
    }

    /// Where Antiphon copied tracks to, by the ID they got there.
    private static func addedTo(_ pair: SyncPair) -> [String: Platform] {
        Dictionary(pair.syncLogs.flatMap(\.changes).filter { $0.kind == .add }.map { ($0.platformTrackId, $0.platform) },
                   uniquingKeysWith: { first, _ in first })
    }

    private static func leading(_ pair: SyncPair) -> Platform {
        pair.syncDirection == .appleToSpotify ? .appleMusic : .spotify
    }

    private func fetch(_ id: UUID, in context: ModelContext) throws -> SyncPair? {
        try context.fetch(FetchDescriptor<SyncPair>(predicate: #Predicate { $0.id == id })).first
    }

    private func summary(_ pair: SyncPair) -> SeamSummary {
        SeamSummary(
            id: pair.id,
            spotify: SeamSide(platform: .spotify, playlistId: pair.spotifyPlaylistId, name: pair.spotifyPlaylistName,
                              artworkURL: pair.spotifyImageURL.flatMap(URL.init(string:))),
            appleMusic: SeamSide(platform: .appleMusic, playlistId: pair.appleMusicPlaylistId, name: pair.appleMusicPlaylistName,
                                 artworkURL: pair.appleMusicImageURL.flatMap(URL.init(string:))),
            direction: pair.syncDirection,
            isMonitored: pair.isMonitored,
            isPaused: pair.isPaused,
            monitorIntervalMinutes: pair.monitorIntervalMinutes ?? preferences.monitorIntervalMinutes,
            lastCheckedAt: pair.lastSyncedAt,
            lastResult: pair.lastSyncResult,
            counts: SeamCounts(tracks: pair.cachedTracks, direction: pair.syncDirection, policy: pair.effectiveRemovalPolicy),
            needsRebuild: pair.needsRebuild
        )
    }
}

extension SeamSummary {
    /// "Spotify → Apple Music" in titles; "Both ways" for two-way seams.
    var directionText: String {
        switch direction {
        case .spotifyToApple: "Spotify → Apple Music"
        case .appleToSpotify: "Apple Music → Spotify"
        case .bidirectional: "Both ways"
        }
    }
}
