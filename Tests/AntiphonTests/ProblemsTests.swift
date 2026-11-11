import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Problems")
@MainActor
struct ProblemsTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Classification

    @Test("Sync failures become problems the person can act on")
    func classification() {
        #expect(ProblemClassifier.problem(for: SpotifyAuthError.notAuthenticated, seamName: "Late Night Drive", now: now)
                == .init(kind: .signedOut, platform: .spotify, message: "Spotify signed you out", retryAt: nil))
        #expect(ProblemClassifier.problem(for: SpotifyAuthError.tokenRefreshFailed, seamName: "X", now: now)?.kind == .signedOut)
        #expect(ProblemClassifier.problem(for: AppleMusicError.notAuthorized, seamName: "X", now: now)
                == .init(kind: .signedOut, platform: .appleMusic, message: "Antiphon can't reach Apple Music", retryAt: nil))
        #expect(ProblemClassifier.problem(for: SyncError.appleMusicPlaylistNotFound, seamName: "Vinyl Rips", now: now)
                == .init(kind: .playlistDeleted, platform: .appleMusic, message: "Vinyl Rips was deleted", retryAt: nil))
        #expect(ProblemClassifier.problem(for: SpotifyAPIError.rateLimited, seamName: "X", now: now)
                == .init(kind: .rateLimited, platform: .spotify, message: "Spotify is busy", retryAt: now.addingTimeInterval(15 * 60)))
    }

    @Test("Spotify refusing one playlist isn't a sign-out: it's that seam's problem")
    func refusedPlaylist() {
        // What the phone logged for a playlist the person only follows.
        let forbidden = SpotifyAPIError.httpError(statusCode: 403, body: #"{"error": {"status": 403, "message": "Forbidden" } }"#)
        #expect(ProblemClassifier.problem(for: forbidden, seamName: "Road Trip", now: now)
                == .init(kind: .writeRefused, platform: .spotify, message: "Spotify won't let apps use Road Trip", retryAt: nil))
        // The account itself refused (not on the app's allowlist) stays global.
        let notRegistered = SpotifyAPIError.httpError(statusCode: 403, body: "The user is not registered for this application.")
        #expect(ProblemClassifier.problem(for: notRegistered, seamName: "Road Trip", now: now)?.kind == .signedOut)
    }

    @Test("A deleted playlist can be made again from the other side when tracks flow toward it")
    func canRecreate() {
        #expect(SeamRecreation.canRecreate(direction: .spotifyToApple, deleted: .appleMusic))
        #expect(!SeamRecreation.canRecreate(direction: .spotifyToApple, deleted: .spotify), "the source is gone: nothing to copy from the rules' point of view")
        #expect(SeamRecreation.canRecreate(direction: .appleToSpotify, deleted: .spotify))
        #expect(SeamRecreation.canRecreate(direction: .bidirectional, deleted: .spotify))
        #expect(SeamRecreation.canRecreate(direction: .bidirectional, deleted: .appleMusic))
    }

    @Test("Recreating leaves the seam as if new on that side: a playlist to create, no stored tracks, a first sync to preview")
    func recreate() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let (context, pair) = try makePair(container)
        pair.lastSyncedAt = now
        pair.unchangedToken = "v1|x"
        pair.appleMusicImageURL = "https://example.com/a.jpg"
        let row = CachedTrack(isrc: "I1", title: "T", artist: "A", source: .both, syncState: .synced)
        row.syncPair = pair
        context.insert(row)
        let deleted = ProblemClassifier.Problem(kind: .playlistDeleted, platform: .appleMusic, message: "Vinyl Rips was deleted", retryAt: nil)
        ProblemStore.record(deleted, for: pair, in: context, now: now)
        try context.save()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let problem = try #require(try await repository.problems().first)

        let seamId = try await repository.recreatePlaylist(for: problem.id)

        #expect(seamId == pair.id)
        let fresh = ModelContext(container)
        let after = try #require(try fresh.fetch(FetchDescriptor<SyncPair>()).first)
        #expect(after.appleMusicPlaylistId.hasPrefix("pending-creation-"))
        #expect(after.spotifyPlaylistId == "sp", "the playlist that's left is untouched")
        #expect(after.cachedTracks.isEmpty)
        #expect(after.lastSyncedAt == nil, "so its first sync is previewed, never run in the background")
        #expect(after.unchangedToken == nil && after.appleMusicImageURL == nil)
        #expect(after.isMonitored, "rules stay")
        #expect(try await repository.problems().isEmpty)
    }

    @Test("A one-way seam whose source was deleted can't be recreated")
    func recreateRefused() async throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let (context, pair) = try makePair(container)
        ProblemStore.record(.init(kind: .playlistDeleted, platform: .spotify, message: "Vinyl Rips was deleted", retryAt: nil),
                            for: pair, in: context, now: now)
        try context.save()
        let repository = SwiftDataSeamRepository(modelContainer: container)
        let problem = try #require(try await repository.problems().first)
        await #expect(throws: SeamRecreation.Failure.self) { _ = try await repository.recreatePlaylist(for: problem.id) }
        #expect(try await repository.problems().count == 1)
    }

    @Test("Only a rejected refresh token means signed out; a busy or down Spotify doesn't")
    func refreshTrouble() {
        #expect(SpotifyAuthError.refreshFailure(status: 400) == .tokenRefreshFailed)
        #expect(SpotifyAuthError.refreshFailure(status: 401) == .tokenRefreshFailed)
        #expect(SpotifyAuthError.refreshFailure(status: 429) == .refreshUnavailable)
        #expect(SpotifyAuthError.refreshFailure(status: 503) == .refreshUnavailable)
        #expect(SpotifyAuthError.refreshFailure(status: nil) == .refreshUnavailable)
        #expect(ProblemClassifier.problem(for: SpotifyAuthError.refreshUnavailable, seamName: "X", now: now) == nil)
    }

    @Test("Temporary network trouble isn't a problem to show")
    func transient() {
        #expect(ProblemClassifier.problem(for: URLError(.timedOut), seamName: "X", now: now) == nil)
        #expect(ProblemClassifier.problem(for: CancellationError(), seamName: "X", now: now) == nil)
    }

    // MARK: - Recording

    private func makePair(_ container: ModelContainer, name: String = "Vinyl Rips") throws -> (ModelContext, SyncPair) {
        let context = ModelContext(container)
        let pair = SyncPair(spotifyPlaylistId: "sp", spotifyPlaylistName: name, appleMusicPlaylistId: "am",
                            appleMusicPlaylistName: name, syncDirection: .spotifyToApple)
        pair.isMonitored = true
        context.insert(pair)
        try context.save()
        return (context, pair)
    }

    @Test("The same problem is recorded once, and a good sync resolves it")
    func recordAndResolve() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let (context, pair) = try makePair(container)
        let deleted = ProblemClassifier.Problem(kind: .playlistDeleted, platform: .appleMusic, message: "Vinyl Rips was deleted", retryAt: nil)
        ProblemStore.record(deleted, for: pair, in: context, now: now)
        ProblemStore.record(deleted, for: pair, in: context, now: now.addingTimeInterval(60))
        try context.save()
        #expect(try context.fetchCount(FetchDescriptor<SyncProblem>()) == 1)

        ProblemStore.resolveAll(for: pair, in: context, now: now)
        try context.save()
        #expect(try context.fetch(FetchDescriptor<SyncProblem>()).allSatisfy { $0.resolvedAt != nil })
    }

    @Test("Sign-outs are recorded once for all seams")
    func signOutIsGlobal() throws {
        let container = try SharedModelContainer.make(inMemory: true)
        let (context, pair) = try makePair(container)
        let signedOut = ProblemClassifier.Problem(kind: .signedOut, platform: .spotify, message: "Spotify signed you out", retryAt: nil)
        ProblemStore.record(signedOut, for: pair, in: context, now: now)
        try context.save()
        let stored = try #require(try context.fetch(FetchDescriptor<SyncProblem>()).first)
        #expect(stored.pair == nil)
    }

    // MARK: - Screen model

    @Test("Signed out: one card, and the monitored seams it pauses")
    func signedOutCard() async throws {
        let accounts = PreviewAccounts()
        accounts.isSpotifyConnected = false
        let seams = PreviewFixtures.seams
        let model = ProblemsModel(seams: PreviewSeamRepository(seams: seams), problems: FixedProblems(), accounts: accounts)
        await model.load()
        let card = try #require(model.signedOut)
        #expect(card.title == "Spotify signed you out")
        #expect(card.message == "Monitoring is paused for all 3 watched seams until you sign in again. Nothing was lost.")
        #expect(model.pausedSeams.map(\.name) == ["Late Night Drive", "Garden Sundays", "Run Club"])
    }

    @Test("Other problems say what broke and when Antiphon retries")
    func otherProblems() async throws {
        let problems = FixedProblems(items: [
            .init(id: UUID(), kind: .playlistDeleted, platform: .appleMusic, seamId: UUID(), message: "Vinyl Rips was deleted",
                  firstSeenAt: now.addingTimeInterval(-2 * 86_400), retryAt: nil),
            .init(id: UUID(), kind: .rateLimited, platform: .appleMusic, seamId: nil, message: "Apple Music is busy",
                  firstSeenAt: now, retryAt: Date(timeIntervalSince1970: 1_800_002_400))
        ])
        let model = ProblemsModel(seams: PreviewSeamRepository(seams: []), problems: problems, accounts: PreviewAccounts(), now: { self.now })
        await model.load()
        #expect(model.signedOut == nil)
        #expect(model.others.map(\.title) == ["Vinyl Rips was deleted", "Apple Music is busy"])
        #expect(model.others.first?.detail == "On Apple Music, 2 days ago")
        #expect(model.others.last?.detail.hasPrefix("Antiphon will retry at ") == true)
        #expect(model.count == 2)
    }
}

struct FixedProblems: ProblemsRepository {
    var items: [ProblemRecord] = []
    func problems() async throws -> [ProblemRecord] { items }
    func recreatePlaylist(for problemId: UUID) async throws -> UUID { UUID() }
}
