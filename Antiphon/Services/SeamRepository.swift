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
        // Where Antiphon copied tracks to, by the ID they got there.
        let addedTo: [String: Platform] = Dictionary(
            pair.syncLogs.flatMap(\.changes).filter { $0.kind == .add }.map { ($0.platformTrackId, $0.platform) },
            uniquingKeysWith: { first, _ in first }
        )
        let leading: Platform = pair.syncDirection == .appleToSpotify ? .appleMusic : .spotify

        let tracks = pair.cachedTracks
            .filter { $0.removalFlag != .extraOnDestination }
            .sorted { $0.addedAt < $1.addedAt }
            .map { track in
                SeamTrack(
                    id: track.id, title: track.title, artist: track.artist, album: track.albumName,
                    artworkURL: track.artworkURL.flatMap(URL.init(string:)),
                    state: TrackRowState(track),
                    isNew: [track.spotifyTrackUri, track.appleMusicTrackId].contains { $0.map(newIds.contains) ?? false },
                    origin: Self.origin(of: track, addedTo: addedTo, leading: leading)
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
            counts: SeamCounts(tracks: pair.cachedTracks, direction: pair.syncDirection)
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
