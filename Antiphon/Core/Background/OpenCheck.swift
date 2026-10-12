import Foundation
import Observation
import SwiftData

/// What opening the app checks, besides each seam's own interval: watched
/// seams sync now under the background rules; unwatched ones are only read
/// (`SyncPlanner.waitingChanges`), so their cards can say what's waiting.
enum OpenCheck {
    /// Opening the app again soon after doesn't check everything again.
    static let cooldown: TimeInterval = AppConstants.Sync.minimumSyncIntervalSeconds

    struct Seam: Sendable, Equatable {
        let id: UUID
        let isMonitored: Bool
        let isPaused: Bool
        /// `nil`: never synced. A first sync is always previewed by the person.
        let lastSyncedAt: Date?
        /// A rebuild after a direction change is previewed by the person too.
        let needsRebuild: Bool
        /// When this app session last checked it (a failed sync leaves
        /// `lastSyncedAt` as it was).
        let checkedAt: Date?
    }

    struct Plan: Equatable {
        var sync: [UUID] = []
        var look: [UUID] = []
    }

    /// `force`: the person pulled to refresh, so seams checked in the last
    /// few minutes are checked again.
    static func plan(_ seams: [Seam], now: Date, force: Bool = false) -> Plan {
        var plan = Plan()
        for seam in seams where !seam.isPaused && !seam.needsRebuild {
            guard let synced = seam.lastSyncedAt else { continue }
            let checked = max(synced, seam.checkedAt ?? .distantPast)
            guard force || now.timeIntervalSince(checked) >= cooldown else { continue }
            if seam.isMonitored { plan.sync.append(seam.id) } else { plan.look.append(seam.id) }
        }
        return plan
    }

    /// Changes a sync would pick up: new tracks on the side the seam
    /// follows, and removals it would carry out or ask about. Questions
    /// flagged before `since` already show as Review on the card.
    static func waiting(rows: [PlanRow], direction: SyncDirection, sourcePlatform: Platform, policy: RemovalPolicy,
                        appleMusicCanRemove: Bool, since: Date) -> Int {
        let newTracks = rows.filter {
            $0.removalFlag == nil && $0.state == .pending && PlanBuilder.allows(direction, from: $0.source.platform)
        }.count
        let flagged = rows.filter { $0.removalFlag != nil }
        let plan = PlanBuilder.build(PlanInput(
            pairId: UUID(), direction: direction, sourcePlatform: sourcePlatform, removalPolicy: policy,
            confidence: .init(), rows: flagged, outcomes: [:], appleMusicCanRemove: appleMusicCanRemove
        ))
        let removals = plan.sides.values.reduce(0) { $0 + $1.removals.count }
        let questions = plan.conflicts.filter { ($0.noticedAt ?? since) >= since }.count
        return newTracks + removals + questions
    }
}

/// Which seams are being checked right now, and what reading the unwatched
/// ones found. Lives for the app session; the cards on Syncs show it.
@MainActor
@Observable
final class SeamChecks {
    static let shared = SeamChecks()

    struct Look: Equatable, Sendable {
        /// Changes a sync would pick up.
        let waiting: Int
        let at: Date
    }

    private(set) var checking: Set<UUID> = []
    private(set) var looks: [UUID: Look] = [:]
    @ObservationIgnored private var checkedAt: [UUID: Date] = [:]
    /// Checks under way: the one opening the app started, and any the
    /// person started by pulling to refresh.
    @ObservationIgnored private var running: [UUID: Task<Void, Never>] = [:]

    func begin(_ ids: some Sequence<UUID>) { checking.formUnion(ids) }

    func finish(_ id: UUID, look: Look?, at date: Date = Date()) {
        checking.remove(id)
        checkedAt[id] = date
        if let look { looks[id] = look }
    }

    /// Waits for a check of `seamId` still running, so a sync the person
    /// starts doesn't collide with it.
    func waitUntilChecked(_ seamId: UUID) async {
        while checking.contains(seamId), let task = running.values.first { await task.value }
    }

    /// The app came to the front: reads unwatched seams, then syncs the
    /// watched ones, under the same gates as background runs (Wi-Fi, Low
    /// Power, quiet hours). Seams the person is syncing are left alone, and
    /// nothing runs while Spotify is signed out (every seam would fail).
    ///
    /// `force`: the person pulled to refresh. Like Sync now, that ignores the
    /// gates and the five minutes; seams already being checked aren't
    /// checked twice.
    @discardableResult
    func runOnOpen(modelContainer: ModelContainer, coordinator: SyncCoordinator, spotifySignedIn: Bool,
                   force: Bool = false, preferences: AppPreferences = .shared) -> Task<Void, Never>? {
        guard spotifySignedIn, force || running.isEmpty else { return nil }
        let pass = UUID()
        let task = Task {
            defer { running[pass] = nil }
            if !force {
                let onWiFi = await NetworkCheck.isOnWiFi()
                if let blocker = MonitorGates.blocker(preferences.monitorGates, onWiFi: onWiFi,
                                                      lowPower: ProcessInfo.processInfo.isLowPowerModeEnabled, now: Date()) {
                    print("[OpenCheck] Skipped: \(blocker)")
                    return
                }
            }
            let seams = Self.seams(in: modelContainer, checkedAt: checkedAt)
            let found = OpenCheck.plan(seams, now: Date(), force: force)
            // Each seam is checked by one pass at a time.
            let free = { (id: UUID) in !self.checking.contains(id) && !coordinator.isSyncing(id) }
            let plan = OpenCheck.Plan(sync: found.sync.filter(free), look: found.look.filter(free))
            let ids = plan.look + plan.sync
            guard !ids.isEmpty else { return }
            begin(ids)

            let planner = SyncPlanner(modelContainer: modelContainer, spotifyClient: SpotifyAPIClient(),
                                      appleMusicManager: AppleMusicManager(), confidence: preferences.confidencePolicy)
            for id in plan.look where checking.contains(id) {
                let started = Date()
                let waiting = try? await planner.waitingChanges(pairId: id, since: started)
                finish(id, look: waiting.map { Look(waiting: $0, at: started) })
            }

            let syncing = plan.sync.filter { checking.contains($0) }
            guard !syncing.isEmpty else { return }
            let engine = SyncEngine(modelContainer: modelContainer, spotifyClient: SpotifyAPIClient(),
                                    appleMusicManager: AppleMusicManager())
            for id in syncing {
                // Forced, the engine's own five-minute cooldown is skipped too.
                _ = await engine.syncAllMonitored(only: [id], preferences: preferences, everySeam: force)
                finish(id, look: nil)
            }
            await WidgetSnapshotWriter.refresh(modelContainer: modelContainer)
        }
        running[pass] = task
        return task
    }

    private static func seams(in container: ModelContainer, checkedAt: [UUID: Date]) -> [OpenCheck.Seam] {
        let pairs = (try? ModelContext(container).fetch(FetchDescriptor<SyncPair>())) ?? []
        return pairs.map {
            OpenCheck.Seam(id: $0.id, isMonitored: $0.isMonitored, isPaused: $0.pausedAt != nil, lastSyncedAt: $0.lastSyncedAt,
                           needsRebuild: $0.needsRebuild, checkedAt: checkedAt[$0.id])
        }
    }
}
