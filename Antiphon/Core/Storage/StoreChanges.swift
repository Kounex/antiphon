import Foundation
import Observation
import SwiftData

/// One signal for "the stored data changed", so every screen that shows it
/// reloads instead of going stale: SwiftData announces each save, from any
/// context in the app (syncs, background runs, answers, edits, unlinking).
/// Saves are coalesced, so a sync saving after every track redraws the
/// screens at most twice a second. Screens use it as
/// `.task(id: StoreChanges.shared.revision)`.
@MainActor
@Observable
final class StoreChanges {
    static let shared = StoreChanges()

    private(set) var revision = 0

    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(interval: Duration = .milliseconds(500), observeSaves: Bool = true) {
        self.interval = interval
        guard observeSaves else { return }
        // Posted on the saving thread: this closure must not be main-actor code.
        observer = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: nil) {
            @Sendable [weak self] _ in
            Task { @MainActor in self?.noteChange() }
        }
    }

    /// Something was saved: redraw once the burst is over (or the interval
    /// has passed), so the reload reads the latest state.
    func noteChange() {
        guard pending == nil else { return }
        pending = Task { [weak self, interval] in
            try? await Task.sleep(for: interval)
            guard let self else { return }
            self.pending = nil
            self.revision += 1
        }
    }
}
