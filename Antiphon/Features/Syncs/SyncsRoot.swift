import AntiphonDesign
import SwiftUI

/// Where the Syncs tab can navigate.
enum SyncsRoute: Hashable {
    case seam(UUID)
    case rules(UUID)
}

/// The Syncs tab: home, seam detail and rules on one navigation stack.
struct SyncsRoot: View {
    let repository: SeamRepository
    let accounts: AccountsService
    let onAccount: () -> Void
    let onNewSeam: () -> Void
    let onSyncNow: (UUID) -> Void

    @Binding var path: [SyncsRoute]
    @State private var home: SyncsHomeModel

    init(path: Binding<[SyncsRoute]>, repository: SeamRepository, accounts: AccountsService,
         onAccount: @escaping () -> Void, onNewSeam: @escaping () -> Void, onSyncNow: @escaping (UUID) -> Void) {
        self.repository = repository
        self.accounts = accounts
        self.onAccount = onAccount
        self.onNewSeam = onNewSeam
        self.onSyncNow = onSyncNow
        _home = State(initialValue: SyncsHomeModel(seams: repository, accounts: accounts))
        _path = path
    }

    var body: some View {
        NavigationStack(path: $path) {
            SyncsHomeView(model: home, path: $path, accountInitials: AccountInitials.from(accounts.spotifyDisplayName),
                          onAccount: onAccount, onNewSeam: onNewSeam, onSyncNow: onSyncNow)
                .navigationDestination(for: SyncsRoute.self) { route in
                    switch route {
                    case .seam(let id):
                        SeamDetailView(model: SeamDetailModel(seamId: id, repository: repository), path: $path, onSyncNow: onSyncNow)
                    case .rules(let id):
                        RulesView(model: RulesModel(seamId: id, repository: repository), path: $path)
                    }
                }
        }
        .task { await home.load() }
    }
}
