import AntiphonDesign
import SwiftUI

/// Where the Syncs tab can navigate.
enum SyncsRoute: Hashable {
    case seam(UUID)
    case rules(UUID)
    case problems
}

/// The Syncs tab: home, seam detail, rules and problems on
/// one navigation stack.
struct SyncsRoot: View {
    let shell: AppShellModel
    let onSyncNow: (UUID) -> Void

    @State private var home: SyncsHomeModel

    init(shell: AppShellModel, onSyncNow: @escaping (UUID) -> Void) {
        self.shell = shell
        self.onSyncNow = onSyncNow
        _home = State(initialValue: SyncsHomeModel(seams: shell.seamRepository, accounts: shell.accounts,
                                                    checkNow: { await shell.checkSeams() }))
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
                    // Each seam gets its own screen and model. Replacing the
                    // path in place (Review, a widget, Library) otherwise
                    // reused the last seam's, so Sync now synced that one.
                    .id(id)
                case .rules(let id):
                    RulesView(model: RulesModel(seamId: id, repository: shell.seamRepository), path: $shell.syncsPath)
                        .id(id)
                case .problems:
                    ProblemsView(model: shell.makeProblems(), onSignIn: { shell.showsSettings = true },
                                 onOpenSeam: { shell.syncsPath.append(.seam($0)) })
                }
            }
        }
        // SyncsHomeView reloads `home` on every store change.
    }

    /// Removals open their question; every other song opens the version picker.
    private func openTrack(_ track: SeamTrack, seamId: UUID) {
        Task {
            if case .removed = track.state {
                await shell.openConflict(rowId: track.id, seamId: seamId)
            } else {
                shell.picking = try? await shell.seamRepository.pickTarget(seamId: seamId, rowId: track.id)
            }
        }
    }
}
