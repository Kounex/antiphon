import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("New seam flow")
@MainActor
struct NewSeamTests {

    private func t(_ n: Int, _ p: Platform, isrc: Bool = true) -> CatalogTrack {
        CatalogTrack(platform: p, id: "\(p.rawValue)-\(n)", title: "Track \(n)", artist: "Artist \(n)",
                     durationMs: 200_000, isrc: isrc ? "ISRC\(n)" : nil)
    }

    private func playlist(_ name: String, _ p: Platform, count: Int? = nil) -> LibraryPlaylist {
        LibraryPlaylist(platform: p, id: "\(p.rawValue)-\(name)", name: name, trackCount: count,
                        artworkURL: nil, detail: "", isEditable: true, blockedReason: nil)
    }

    // MARK: - Overlap

    @Test("Compare: 33 only on Spotify, 31 on both, 6 only on Apple Music")
    func storyboardOverlap() {
        let spotify = (0..<64).map { t($0, .spotify) }
        let apple = (33..<64).map { t($0, .appleMusic) } + (100..<106).map { t($0, .appleMusic) }
        let overlap = Overlap.compute(source: spotify, target: apple)
        #expect(overlap.sourceOnly.count == 33)
        #expect(overlap.both.count == 31)
        #expect(overlap.targetOnly.count == 6)
        #expect(overlap.accessibilityLabel(sourceName: "Spotify", targetName: "Apple Music")
                == "33 only on Spotify, 31 on both, 6 only on Apple Music")
    }

    @Test("Without ISRCs, the same title, artist and length still counts as shared")
    func overlapByMetadata() {
        let overlap = Overlap.compute(source: [t(1, .spotify, isrc: false)], target: [t(1, .appleMusic, isrc: false)])
        #expect(overlap.both.count == 1)
    }

    // MARK: - Twin ranking

    @Test("Suggestions rank by shared tracks, then by name")
    func ranking() {
        let source = playlist("Workout Mix 2026", .spotify)
        let ranked = TwinRanker.rank(source: source, candidates: [
            .init(playlist: playlist("Workout", .appleMusic), shared: 12),
            .init(playlist: playlist("Gym Rotation", .appleMusic), shared: 31),
            .init(playlist: playlist("Workout Mix 2026", .appleMusic), shared: nil),
            .init(playlist: playlist("Vinyl Rips", .appleMusic), shared: 0)
        ])
        #expect(ranked.map(\.playlist.name) == ["Gym Rotation", "Workout", "Workout Mix 2026", "Vinyl Rips"])
        #expect(ranked.first?.isSuggested == true)
    }

    @Test("Name similarity picks which candidates to fetch first")
    func nameSimilarity() {
        #expect(TwinRanker.nameSimilarity("Workout Mix 2026", "Workout") > TwinRanker.nameSimilarity("Workout Mix 2026", "Vinyl Rips"))
        #expect(TwinRanker.nameSimilarity("Late Night Drive", "late night drive") == 1)
    }

    // MARK: - Copy

    @Test("Direction sentence recounts what will happen in tracks")
    func consequence() {
        #expect(NewSeamCopy.consequence(direction: .bidirectional, sourceName: "Workout Mix 2026", targetName: "Gym Rotation",
                                        addsToTarget: 33, addsToSource: 6)
                == "Adds 33 tracks to Gym Rotation and 6 to Workout Mix 2026. From then on, anything you add on either side shows up on the other.")
        #expect(NewSeamCopy.consequence(direction: .spotifyToApple, sourceName: "Workout Mix 2026", targetName: "Gym Rotation",
                                        addsToTarget: 33, addsToSource: 6)
                == "Adds 33 tracks to Gym Rotation. From then on, tracks you add to Workout Mix 2026 are copied over. Nothing is removed.")
        #expect(NewSeamCopy.consequence(direction: .spotifyToApple, sourceName: "Road Trip", targetName: "Road Trip",
                                        addsToTarget: 0, addsToSource: 0)
                == "Nothing to add yet. From then on, tracks you add to Road Trip are copied over. Nothing is removed.")
    }

    @Test("The finish screen states the outcome")
    func doneCopy() {
        #expect(NewSeamCopy.doneTitle(name: "Workout Mix 2026") == "Workout Mix 2026 is stitched")
        #expect(NewSeamCopy.doneBody(added: 35, monitoring: true, interval: 15, direction: .bidirectional)
                == "35 tracks added. Antiphon now watches both playlists, about every 15 min.")
        // One way: only the source is watched for new tracks.
        #expect(NewSeamCopy.doneBody(added: 35, monitoring: true, interval: 15, direction: .spotifyToApple)
                == "35 tracks added. Antiphon now watches Spotify for new tracks, about every 15 min.")
        #expect(NewSeamCopy.doneBody(added: 35, monitoring: true, interval: 15, direction: .appleToSpotify)
                == "35 tracks added. Antiphon now watches Apple Music for new tracks, about every 15 min.")
        #expect(NewSeamCopy.doneBody(added: 1, monitoring: false, interval: 15, direction: .spotifyToApple)
                == "1 track added. Antiphon syncs this seam when you ask.")
    }

    // MARK: - Queue

    @Test("Picking several playlists queues them; each gets its own twin")
    func queue() {
        var queue = NewSeamQueue(sources: [playlist("Workout Mix 2026", .spotify), playlist("Discover Weekly", .spotify)])
        #expect(queue.current?.name == "Workout Mix 2026")
        #expect(queue.positionText == "1 of 2")
        #expect(queue.next?.name == "Discover Weekly")
        queue.advance()
        #expect(queue.current?.name == "Discover Weekly")
        #expect(queue.next == nil)
        queue.advance()
        #expect(queue.isFinished)
    }

    // MARK: - Creating the seam

    @Test("Creating a seam stores both sides; a new twin waits for the first sync")
    func create() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let id = try await repository.create(SeamDraft(
            source: playlist("Workout Mix 2026", .spotify), target: .new(name: "Workout Mix 2026"),
            direction: .bidirectional, removalPolicy: .ask, isMonitored: true, monitorIntervalMinutes: 60
        ))
        let pair = try #require(try ModelContext(container).fetch(FetchDescriptor<SyncPair>()).first { $0.id == id })
        #expect(pair.spotifyPlaylistId == "Spotify-Workout Mix 2026")
        #expect(pair.appleMusicPlaylistId.hasPrefix("pending-creation-"))
        #expect(pair.appleMusicPlaylistName == "Workout Mix 2026")
        #expect(pair.syncDirection == .bidirectional)
        #expect(pair.removalPolicy == .ask)
        #expect(pair.monitorIntervalMinutes == 60)
        #expect(pair.lastSyncedAt == nil)
    }

    @Test("An Apple Music source with a Spotify twin is stored the right way round")
    func createFromAppleMusic() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let repository = SwiftDataSeamRepository(modelContainer: container)
        _ = try await repository.create(SeamDraft(
            source: playlist("Running", .appleMusic), target: .existing(playlist("Run Club", .spotify)),
            direction: .appleToSpotify, removalPolicy: .keep, isMonitored: false, monitorIntervalMinutes: nil
        ))
        let pair = try #require(try ModelContext(container).fetch(FetchDescriptor<SyncPair>()).first)
        #expect(pair.appleMusicPlaylistName == "Running")
        #expect(pair.spotifyPlaylistName == "Run Club")
        #expect(pair.isMonitored == false)
    }

    @Test("Monitoring never runs a seam's first sync: that one is always previewed")
    func monitoringSkipsUnsynced() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "s", spotifyPlaylistName: "A", appleMusicPlaylistId: "a",
                            appleMusicPlaylistName: "A", syncDirection: .spotifyToApple)
        pair.isMonitored = true
        context.insert(pair)
        try context.save()
        let engine = SyncEngine(modelContainer: container, spotifyClient: SpotifyAPIClient(), appleMusicManager: AppleMusicManager())
        #expect(await engine.syncAllMonitored().isEmpty)
    }
}

@Suite("Sync time estimate")
struct SyncETATests {
    @Test("Estimates from the pace so far, rounded like a person would")
    func eta() {
        #expect(SyncETA.text(done: 20, total: 35, elapsed: 53) == "about 40 s left")
        #expect(SyncETA.text(done: 10, total: 130, elapsed: 30) == "about 6 min left")
        #expect(SyncETA.text(done: 1, total: 35, elapsed: 5) == nil, "too early to tell")
        #expect(SyncETA.text(done: 35, total: 35, elapsed: 90) == nil)
        #expect(SyncETA.text(done: 30, total: 31, elapsed: 30) == "a few seconds left")
    }
}

/// Canned libraries for both platforms.
struct FakeLibrary: LibraryService {
    var playlists: [Platform: [LibraryPlaylist]]
    var tracks: [String: [CatalogTrack]]
    /// Playlists Spotify won't hand over.
    var refused: Set<String> = []

    func canRead(_ playlist: LibraryPlaylist) async -> Bool { !refused.contains(playlist.id) }

    func playlists(on platform: Platform) async throws -> [LibraryPlaylist] { playlists[platform] ?? [] }
    func tracks(of playlist: LibraryPlaylist) async throws -> [CatalogTrack] { tracks[playlist.id] ?? [] }
}

@Suite("New seam model", .serialized)
@MainActor
struct NewSeamModelTests {

    private func p(_ name: String, _ platform: Platform, blocked: String? = nil, count: Int? = nil) -> LibraryPlaylist {
        LibraryPlaylist(platform: platform, id: "\(platform.rawValue)-\(name)", name: name, trackCount: count,
                        artworkURL: nil, detail: "", isEditable: blocked == nil, blockedReason: blocked)
    }

    private func t(_ n: Int, _ platform: Platform) -> CatalogTrack {
        CatalogTrack(platform: platform, id: "\(platform.rawValue)-\(n)", title: "Track \(n)", artist: "A", durationMs: 200_000, isrc: "I\(n)")
    }

    private func makeModel(linked: [SeamSummary] = []) throws -> (NewSeamModel, ModelContainer) {
        let workout = p("Workout Mix 2026", .spotify, count: 64)
        let library = FakeLibrary(
            playlists: [
                .spotify: [workout, p("Discover Weekly", .spotify, blocked: "Made by Spotify."), p("Late Night Drive", .spotify)],
                .appleMusic: [p("Gym Rotation", .appleMusic), p("Workout", .appleMusic), p("Vinyl Rips", .appleMusic)]
            ],
            tracks: [
                workout.id: (0..<64).map { t($0, .spotify) },
                "Apple Music-Gym Rotation": (33..<64).map { t($0, .appleMusic) } + (100..<106).map { t($0, .appleMusic) },
                "Apple Music-Workout": (52..<64).map { t($0, .appleMusic) }
            ]
        )
        let container = try SharedModelContainer.make(inMemory: true)
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let defaults = UserDefaults(suiteName: "nsm-\(UUID().uuidString)")!
        // Late Night Drive is already in a seam.
        let context = ModelContext(container)
        context.insert(SyncPair(spotifyPlaylistId: "Spotify-Late Night Drive", spotifyPlaylistName: "Late Night Drive",
                                appleMusicPlaylistId: "Apple Music-Late Night", appleMusicPlaylistName: "Late Night",
                                syncDirection: .spotifyToApple))
        try context.save()
        return (NewSeamModel(library: library, seams: repository, preferences: AppPreferences(defaults: defaults)), container)
    }

    @Test("A playlist already in a seam isn't offered as another one's twin")
    func linkedPlaylistIsNoTwin() async throws {
        let (model, container) = try makeModel()
        // Gym Rotation is the twin of some other Spotify playlist already.
        let context = ModelContext(container)
        context.insert(SyncPair(spotifyPlaylistId: "Spotify-Other", spotifyPlaylistName: "Other",
                                appleMusicPlaylistId: "Apple Music-Gym Rotation", appleMusicPlaylistName: "Gym Rotation",
                                syncDirection: .spotifyToApple))
        try context.save()
        await model.loadPlaylists()
        let workout = try #require(model.visiblePlaylists.first { $0.name == "Workout Mix 2026" })
        model.toggle(workout)
        model.startQueue()
        await model.loadTwins()
        #expect(!model.suggestions.map(\.playlist.name).contains("Gym Rotation"))
        #expect(model.suggestions.map(\.playlist.name).contains("Workout"))
    }

    @Test("Only Spotify's own playlists are ruled out up front; someone else's is asked about when it's picked")
    func whatIsBlockedUpFront() {
        #expect(LibraryPlaylist.spotifyBlockedReason(ownerId: "spotify")
                == "Made by Spotify. Spotify doesn't let apps read these.")
        // A friend's playlist may be one the person collaborates on, even
        // when Spotify's `collaborative` flag doesn't say so.
        #expect(LibraryPlaylist.spotifyBlockedReason(ownerId: "someone") == nil)
        #expect(LibraryPlaylist.spotifyBlockedReason(ownerId: "me") == nil)
    }

    private func friends(_ library: inout FakeLibrary) -> LibraryPlaylist {
        let shared = LibraryPlaylist(platform: .spotify, id: "Spotify-Shared", name: "Shared with Tom", trackCount: 40,
                                     artworkURL: nil, detail: "", isEditable: false, blockedReason: nil, isOwn: false,
                                     needsAccessCheck: true)
        library.playlists[.spotify, default: []].append(shared)
        return shared
    }

    @Test("A friend's playlist Spotify lets Antiphon read can be picked")
    func friendsPlaylistReadable() async throws {
        var library = FakeLibrary(playlists: [:], tracks: [:])
        let shared = friends(&library)
        let model = NewSeamModel(library: library, seams: SwiftDataSeamRepository(modelContainer: try SharedModelContainer.make(inMemory: true)),
                                 preferences: AppPreferences(defaults: UserDefaults(suiteName: "nsm-\(UUID().uuidString)")!))
        await model.loadPlaylists()
        await model.pick(shared)
        #expect(model.isSelected(shared))
        #expect(model.unavailableReason(for: shared) == nil)
    }

    private func friendsTwin(refused: Bool) async throws -> [String] {
        let apple = LibraryPlaylist(platform: .appleMusic, id: "Apple Music-WubWub", name: "selected#WubWub", trackCount: nil,
                                    artworkURL: nil, detail: "", isEditable: true, blockedReason: nil)
        let friends = LibraryPlaylist(platform: .spotify, id: "Spotify-WubWub", name: "selected#WubWub", trackCount: 59,
                                      artworkURL: nil, detail: "", isEditable: false, blockedReason: nil, isOwn: false,
                                      needsAccessCheck: true)
        // Another friend's playlist with an unrelated name: never asked about, never offered.
        let far = LibraryPlaylist(platform: .spotify, id: "Spotify-Far", name: "Zzz", trackCount: 5, artworkURL: nil, detail: "",
                                  isEditable: false, blockedReason: nil, isOwn: false, needsAccessCheck: true)
        var names = (1...6).map { "Mix \($0)" }.map {
            LibraryPlaylist(platform: .spotify, id: "Spotify-\($0)", name: $0, trackCount: 1, artworkURL: nil, detail: "",
                            isEditable: true, blockedReason: nil)
        }
        names.append(contentsOf: [friends, far])
        var library = FakeLibrary(playlists: [.appleMusic: [apple], .spotify: names], tracks: [:])
        if refused { library.refused = [friends.id] }
        let model = NewSeamModel(library: library, seams: SwiftDataSeamRepository(modelContainer: try SharedModelContainer.make(inMemory: true)),
                                 preferences: AppPreferences(defaults: UserDefaults(suiteName: "nsm-\(UUID().uuidString)")!))
        model.preselect(apple)
        await model.loadTwins()
        return model.suggestions.map(\.playlist.name)
    }

    @Test("Starting from Apple Music, a friend's Spotify playlist Antiphon can read is offered as the twin")
    func friendsPlaylistAsTwin() async throws {
        let offered = try await friendsTwin(refused: false)
        #expect(offered.contains("selected#WubWub"))
        #expect(!offered.contains("Zzz"), "one that isn't among the closest names isn't asked about, so it isn't offered")
    }

    @Test("One Spotify refuses isn't offered as a twin")
    func refusedPlaylistIsNoTwin() async throws {
        #expect(!(try await friendsTwin(refused: true)).contains("selected#WubWub"))
    }

    @Test("One Spotify refuses is said so, with the reason, and isn't picked")
    func friendsPlaylistRefused() async throws {
        var library = FakeLibrary(playlists: [:], tracks: [:])
        let shared = friends(&library)
        library.refused = [shared.id]
        let model = NewSeamModel(library: library, seams: SwiftDataSeamRepository(modelContainer: try SharedModelContainer.make(inMemory: true)),
                                 preferences: AppPreferences(defaults: UserDefaults(suiteName: "nsm-\(UUID().uuidString)")!))
        await model.loadPlaylists()
        await model.pick(shared)
        #expect(!model.isSelected(shared))
        #expect(model.unavailableReason(for: shared) == LibraryPlaylist.followedReason)
    }

    @Test("Playlists already in a seam, or blocked by Spotify, can't be picked")
    func pickable() async throws {
        let (model, _) = try makeModel()
        await model.loadPlaylists()
        let byName = Dictionary(uniqueKeysWithValues: model.visiblePlaylists.map { ($0.name, $0) })
        #expect(model.unavailableReason(for: try #require(byName["Late Night Drive"])) == "Already in a seam")
        #expect(model.unavailableReason(for: try #require(byName["Discover Weekly"])) == "Made by Spotify.")
        #expect(model.unavailableReason(for: try #require(byName["Workout Mix 2026"])) == nil)
    }

    @Test("A seam unlinked while New seam is open frees its playlists (no stale \"Already in a seam\")")
    func unlinkedFreesPlaylists() async throws {
        let (model, container) = try makeModel()
        await model.loadPlaylists()
        let late = try #require(model.visiblePlaylists.first { $0.name == "Late Night Drive" })
        #expect(model.unavailableReason(for: late) == "Already in a seam")
        let context = ModelContext(container)
        for pair in try context.fetch(FetchDescriptor<SyncPair>()) { context.delete(pair) }
        try context.save()
        await model.refreshLinked()
        #expect(model.unavailableReason(for: late) == nil)
    }

    @Test("Search narrows the list")
    func search() async throws {
        let (model, _) = try makeModel()
        await model.loadPlaylists()
        model.search = "work"
        #expect(model.visiblePlaylists.map(\.name) == ["Workout Mix 2026"])
    }

    @Test("The best twin is ranked first and pre-selected")
    func twins() async throws {
        let (model, _) = try makeModel()
        await model.loadPlaylists()
        model.toggle(model.visiblePlaylists.first { $0.name == "Workout Mix 2026" }!)
        model.startQueue()
        await model.loadTwins()
        #expect(model.suggestions.first?.playlist.name == "Gym Rotation")
        #expect(model.suggestions.first?.shared == 31)
        #expect(model.twinChoice == .existing(model.suggestions[0].playlist))
    }

    @Test("Compare and the direction sentence use the real overlap")
    func compareAndConsequence() async throws {
        let (model, _) = try makeModel()
        await model.loadPlaylists()
        model.toggle(model.visiblePlaylists.first { $0.name == "Workout Mix 2026" }!)
        model.startQueue()
        await model.loadTwins()
        await model.loadOverlap()
        #expect(model.overlap?.sourceOnly.count == 33)
        #expect(model.overlap?.targetOnly.count == 6)
        #expect(model.direction == .spotifyToApple, "new seams are one way by default")
        #expect(model.consequence == "Adds 33 tracks to Gym Rotation. From then on, tracks you add to Workout Mix 2026 are copied over. Nothing is removed.")
        model.direction = .bidirectional
        #expect(model.consequence.hasPrefix("Adds 33 tracks to Gym Rotation and 6 to Workout Mix 2026."))
    }

    @Test("A new twin adds every source track")
    func createNewTwin() async throws {
        let (model, _) = try makeModel()
        await model.loadPlaylists()
        model.toggle(model.visiblePlaylists.first { $0.name == "Workout Mix 2026" }!)
        model.startQueue()
        await model.loadTwins()
        model.twinChoice = .createNew
        await model.loadOverlap()
        #expect(model.consequence.hasPrefix("Adds 64 tracks to Workout Mix 2026."))
    }

    @Test("Preview changes creates the seam with the chosen rules")
    func createSeam() async throws {
        let (model, container) = try makeModel()
        await model.loadPlaylists()
        model.toggle(model.visiblePlaylists.first { $0.name == "Workout Mix 2026" }!)
        model.startQueue()
        await model.loadTwins()
        model.direction = .bidirectional
        model.mirrorRemovals = false
        model.keepWatching = true
        model.interval = 60
        let id = try await model.createSeam()
        let pair = try #require(try ModelContext(container).fetch(FetchDescriptor<SyncPair>()).first { $0.id == id })
        #expect(pair.appleMusicPlaylistName == "Gym Rotation")
        #expect(pair.syncDirection == .bidirectional)
        #expect(pair.removalPolicy == .ask)
        #expect(pair.monitorIntervalMinutes == 60)
    }
}
