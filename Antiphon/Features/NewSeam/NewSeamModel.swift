import AntiphonDesign
import Foundation
import Observation

/// Pick playlists → find each one's twin → compare → choose how to sync.
/// Nothing is written until the first preview is approved.
@MainActor
@Observable
final class NewSeamModel {
    enum TwinChoice: Hashable {
        case existing(LibraryPlaylist)
        case createNew
    }

    enum Region: Hashable { case sourceOnly, targetOnly, both }

    // Pick
    var side: Platform = .spotify
    var search = ""
    private(set) var playlists: [Platform: [LibraryPlaylist]] = [:]
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var selected: [LibraryPlaylist] = []
    private(set) var queue: NewSeamQueue?

    // Twin
    private(set) var suggestions: [TwinRanker.Suggestion] = []
    private(set) var isRankingTwins = false
    var twinChoice: TwinChoice?

    // Compare
    private(set) var overlap: Overlap?
    var region: Region = .sourceOnly

    // How to sync
    var direction: SyncDirection = .spotifyToApple
    /// Two-way: off means "ask before removing". One-way: "remove it too".
    var mirrorRemovals = false
    var keepWatching = true
    var interval = 15

    private let library: LibraryService
    private let seams: SeamRepository
    private let preferences: AppPreferences
    private var linkedPlaylistIds: Set<String>
    private var trackCache: [String: [CatalogTrack]] = [:]

    init(library: LibraryService, seams: SeamRepository, preferences: AppPreferences, linkedPlaylistIds: Set<String>) {
        self.library = library
        self.seams = seams
        self.preferences = preferences
        self.linkedPlaylistIds = linkedPlaylistIds
    }

    // MARK: - Pick

    func loadPlaylists() async {
        if let seams = try? await seams.seams() {
            linkedPlaylistIds.formUnion(seams.flatMap { [$0.spotify.playlistId, $0.appleMusic.playlistId] })
        }
        guard playlists[side] == nil else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            playlists[side] = try await library.playlists(on: side)
            loadError = nil
        } catch {
            loadError = "Antiphon couldn't load your \(side.rawValue) playlists. Check that you're signed in."
        }
    }

    var visiblePlaylists: [LibraryPlaylist] {
        let all = playlists[side] ?? []
        guard !search.isEmpty else { return all }
        return all.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    func unavailableReason(for playlist: LibraryPlaylist) -> String? {
        if linkedPlaylistIds.contains(playlist.id) { return "Already in a seam" }
        return playlist.blockedReason
    }

    func isSelected(_ playlist: LibraryPlaylist) -> Bool { selected.contains { $0.id == playlist.id } }

    func toggle(_ playlist: LibraryPlaylist) {
        guard unavailableReason(for: playlist) == nil else { return }
        if let index = selected.firstIndex(where: { $0.id == playlist.id }) {
            selected.remove(at: index)
        } else {
            selected.append(playlist)
        }
    }

    /// Switching sides starts a fresh selection: a seam starts from one side.
    func switchSide(to platform: Platform) {
        guard platform != side else { return }
        side = platform
        selected = []
    }

    func startQueue() {
        queue = NewSeamQueue(sources: selected)
        prepareForCurrent()
    }

    /// Moves to the next picked playlist. Returns false when all are done.
    func advanceQueue() -> Bool {
        queue?.advance()
        guard let queue, !queue.isFinished else { return false }
        prepareForCurrent()
        return true
    }

    var source: LibraryPlaylist? { queue?.current }

    // MARK: - Twin

    func loadTwins() async {
        guard let source else { return }
        isRankingTwins = true
        defer { isRankingTwins = false }
        let others = (try? await library.playlists(on: source.platform.other))?.filter { $0.isEditable && $0.blockedReason == nil } ?? []
        // Fetch tracks only for the closest names, to keep requests bounded.
        let closest = others.sorted { TwinRanker.nameSimilarity(source.name, $0.name) > TwinRanker.nameSimilarity(source.name, $1.name) }.prefix(6)
        let sourceTracks = await tracks(of: source)
        var candidates: [TwinRanker.Candidate] = []
        for playlist in others {
            if closest.contains(where: { $0.id == playlist.id }) {
                let shared = Overlap.compute(source: sourceTracks, target: await tracks(of: playlist)).both.count
                candidates.append(.init(playlist: playlist, shared: shared))
            } else {
                candidates.append(.init(playlist: playlist, shared: nil))
            }
        }
        suggestions = TwinRanker.rank(source: source, candidates: candidates)
        if twinChoice == nil {
            twinChoice = suggestions.first(where: \.isSuggested).map { .existing($0.playlist) } ?? .createNew
        }
    }

    var targetName: String {
        switch twinChoice {
        case .existing(let playlist): playlist.name
        case .createNew, nil: source?.name ?? ""
        }
    }

    // MARK: - Compare

    func loadOverlap() async {
        guard let source else { return }
        let sourceTracks = await tracks(of: source)
        switch twinChoice {
        case .existing(let target):
            overlap = Overlap.compute(source: sourceTracks, target: await tracks(of: target))
        case .createNew, nil:
            overlap = Overlap(sourceOnly: sourceTracks, both: [], targetOnly: [])
        }
    }

    var regionTracks: [CatalogTrack] {
        switch region {
        case .sourceOnly: overlap?.sourceOnly ?? []
        case .targetOnly: overlap?.targetOnly ?? []
        case .both: overlap?.both ?? []
        }
    }

    // MARK: - How to sync

    var consequence: String {
        NewSeamCopy.consequence(
            direction: direction, sourceName: source?.name ?? "", targetName: targetName,
            addsToTarget: overlap?.sourceOnly.count ?? source?.trackCount ?? 0,
            addsToSource: overlap?.targetOnly.count ?? 0
        )
    }

    var removalPolicy: RemovalPolicy {
        if mirrorRemovals { return .mirror }
        return direction == .bidirectional ? .ask : .keep
    }

    var orderNote: String {
        "Order follows \(source?.name ?? "the playlist you started from"), the one you started from. Change this in Rules."
    }

    func createSeam() async throws -> UUID {
        guard let source else { throw DryRunStageA.Failure.pairNotFound }
        let target: SeamDraft.Target = switch twinChoice {
        case .existing(let playlist): .existing(playlist)
        case .createNew, nil: .new(name: source.name)
        }
        return try await seams.create(SeamDraft(
            source: source, target: target, direction: direction, removalPolicy: removalPolicy,
            isMonitored: keepWatching && interval > 0, monitorIntervalMinutes: interval
        ))
    }

    // MARK: - Private

    private func prepareForCurrent() {
        suggestions = []
        twinChoice = nil
        overlap = nil
        region = .sourceOnly
        direction = source?.platform == .appleMusic ? .appleToSpotify : .spotifyToApple
        mirrorRemovals = preferences.newSeamRemovalPolicy == .mirror
        keepWatching = preferences.newSeamMonitoring
        interval = preferences.monitorIntervalMinutes
    }

    private func tracks(of playlist: LibraryPlaylist) async -> [CatalogTrack] {
        if let cached = trackCache[playlist.id] { return cached }
        let tracks = (try? await library.tracks(of: playlist)) ?? []
        trackCache[playlist.id] = tracks
        return tracks
    }
}
