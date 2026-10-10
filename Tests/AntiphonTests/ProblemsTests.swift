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
}
