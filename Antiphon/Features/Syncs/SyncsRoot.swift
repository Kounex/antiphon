import AntiphonDesign
import SwiftUI

/// Where the Syncs tab can navigate.
enum SyncsRoute: Hashable {
    case seam(UUID)
    case rules(UUID)
    case problems
    case match(seamId: UUID, rowId: UUID)
}

/// The Syncs tab: home, seam detail, rules, match detail and problems on
/// one navigation stack.
struct SyncsRoot: View {
    let shell: AppShellModel
    let onSyncNow: (UUID) -> Void

    @State private var home: SyncsHomeModel

    init(shell: AppShellModel, onSyncNow: @escaping (UUID) -> Void) {
        self.shell = shell
        self.onSyncNow = onSyncNow
        _home = State(initialValue: SyncsHomeModel(seams: shell.seamRepository, accounts: shell.accounts))
    }

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.syncsPath) {
            SyncsHomeView(
                model: home, path: $shell.syncsPath,
                accountInitials: AccountInitials.from(shell.accounts.spotifyDisplayName),
                problemCount: shell.problemCount,
                onAccount: { shell.showsSettings = true },
                onNewSeam: { shell.showsNewSeam = true },
                onSyncNow: onSyncNow,
                onReviewAll: { shell.reviewTarget = .init(seamId: nil) }
            )
            .navigationDestination(for: SyncsRoute.self) { route in
                switch route {
                case .seam(let id):
                    SeamDetailView(
                        model: SeamDetailModel(seamId: id, repository: shell.seamRepository), path: $shell.syncsPath,
                        onSyncNow: onSyncNow,
                        onReview: { shell.reviewTarget = .init(seamId: id) },
                        onOpenTrack: { track in openTrack(track, seamId: id) }
                    )
                case .rules(let id):
                    RulesView(model: RulesModel(seamId: id, repository: shell.seamRepository), path: $shell.syncsPath)
                case .problems:
                    ProblemsView(model: shell.makeProblems(), onSignIn: { shell.showsSettings = true },
                                 onOpenSeam: { shell.syncsPath.append(.seam($0)) })
                case .match(let seamId, let rowId):
                    MatchDetailLoader(shell: shell, seamId: seamId, rowId: rowId) { shell.syncsPath.removeLast() }
                }
            }
        }
        .task { await home.load() }
    }

    /// Close matches open their evidence; removals open their question.
    private func openTrack(_ track: SeamTrack, seamId: UUID) {
        switch track.state {
        case .review:
            shell.syncsPath.append(.match(seamId: seamId, rowId: track.id))
        case .removed:
            Task { await shell.openConflict(rowId: track.id, seamId: seamId) }
        default:
            break
        }
    }
}

/// Loads a close match for its detail screen, then decides through the sync service.
private struct MatchDetailLoader: View {
    let shell: AppShellModel
    let seamId: UUID
    let rowId: UUID
    let onDone: () -> Void
    @State private var item: ReviewItem?

    var body: some View {
        Group {
            if let item {
                MatchDetailView(model: shell.makeMatchDetail(item)) { candidate in
                    Task {
                        _ = try? await shell.sync.decide(candidate.map { .accept($0) } ?? .skip, for: item.key, seamId: seamId)
                        onDone()
                    }
                }
            } else {
                ProgressView()
            }
        }
        .task { item = await shell.reviewItem(rowId: rowId, seamId: seamId) }
    }
}
