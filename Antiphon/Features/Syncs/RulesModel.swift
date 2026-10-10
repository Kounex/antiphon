import AntiphonDesign
import Foundation
import Observation

/// A seam's rules. Every change saves immediately; each rule shows its
/// consequence in one line.
@MainActor
@Observable
final class RulesModel {
    let seamId: UUID
    private(set) var rules: SeamRules?
    private(set) var originalDirection: SyncDirection?
    private(set) var toast: String?
    private(set) var seamName = ""

    private let repository: SeamRepository

    init(seamId: UUID, repository: SeamRepository) {
        self.seamId = seamId
        self.repository = repository
    }

    func load() async {
        rules = try? await repository.rules(for: seamId)
        originalDirection = originalDirection ?? rules?.direction
        seamName = (try? await repository.detail(for: seamId))?.summary.name ?? ""
    }

    func update(_ change: (inout SeamRules) -> Void) {
        guard var rules else { return }
        let wasPaused = rules.isPaused
        change(&rules)
        // A one-way seam can't ask; a two-way seam asks by default.
        if rules.direction == .bidirectional, self.rules?.direction != .bidirectional { rules.removalPolicy = .ask }
        if rules.direction != .bidirectional, rules.removalPolicy == .ask { rules.removalPolicy = .keep }
        self.rules = rules
        if rules.isPaused != wasPaused {
            toast = rules.isPaused ? "Paused. Antiphon won't change \(seamName) until you turn this back on." : "Resumed."
        }
        let saved = rules
        Task { try? await repository.update(saved, for: seamId) }
    }

    func dismissToast() { toast = nil }

    func unlink() async {
        try? await repository.unlink(seamId)
    }

    // MARK: - Presentation

    var directionChoice: SeamDirection {
        rules?.direction == .bidirectional ? .twoWay : .oneWay
    }

    func setDirection(_ choice: SeamDirection) {
        update { rules in
            switch choice {
            case .twoWay: rules.direction = .bidirectional
            case .oneWay where rules.direction == .bidirectional: rules.direction = .spotifyToApple
            case .oneWay: break
            }
        }
    }

    func swapDirection() {
        update { rules in
            switch rules.direction {
            case .spotifyToApple: rules.direction = .appleToSpotify
            case .appleToSpotify: rules.direction = .spotifyToApple
            case .bidirectional: break
            }
        }
    }

    /// Shown once the direction differs from when the screen opened.
    var rebuildNote: String? {
        guard let rules, let originalDirection, rules.direction != originalDirection else { return nil }
        return "The next sync starts fresh and shows you a preview before it changes anything."
    }

    var removalOptions: [DirectionPicker<RemovalPolicy>.Option] {
        if rules?.direction == .bidirectional {
            return [.init(.ask, title: "Ask me"), .init(.mirror, title: "Remove it too"), .init(.keep, title: "Keep it")]
        }
        return [.init(.keep, title: "Keep it"), .init(.mirror, title: "Remove it too")]
    }
}
