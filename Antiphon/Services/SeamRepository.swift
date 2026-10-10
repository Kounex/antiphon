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
}

/// Read and edit seams. Views talk to this, never to SwiftData.
protocol SeamRepository: Sendable {
    func seams() async throws -> [SeamSummary]
    func detail(for id: UUID) async throws -> SeamDetail?
    func rules(for id: UUID) async throws -> SeamRules?
    func update(_ rules: SeamRules, for id: UUID) async throws
    /// Removes the seam from Antiphon. Both playlists stay exactly as they are.
    func unlink(_ id: UUID) async throws
}

/// `SeamRepository` over the shared SwiftData store.
actor SwiftDataSeamRepository: SeamRepository {
    private let modelContainer: ModelContainer
    private let preferences: AppPreferences
    /// How far back "New" looks when a seam has never been opened.
    private let newWindow: TimeInterval = 7 * 24 * 3600

    init(modelContainer: ModelContainer, preferences: AppPreferences = .shared) {
        self.modelContainer = modelContainer
        self.preferences = preferences
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

        let tracks = pair.cachedTracks
            .filter { $0.removalFlag != .extraOnDestination }
            .sorted { $0.addedAt < $1.addedAt }
            .map { track in
                SeamTrack(
                    id: track.id, title: track.title, artist: track.artist, album: track.albumName,
                    artworkURL: track.artworkURL.flatMap(URL.init(string:)),
                    state: TrackRowState(track),
                    isNew: [track.spotifyTrackUri, track.appleMusicTrackId].contains { $0.map(newIds.contains) ?? false }
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
            isPaused: pair.isPaused
        )
    }

    func update(_ rules: SeamRules, for id: UUID) async throws {
        let context = ModelContext(modelContainer)
        guard let pair = try fetch(id, in: context) else { return }
        pair.syncDirection = rules.direction
        pair.removalPolicy = rules.removalPolicy
        pair.isMonitored = rules.isMonitored
        pair.monitorIntervalMinutes = rules.monitorIntervalMinutes
        pair.notifyNewTracks = rules.notifyNewTracks
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

    // MARK: - Private

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
