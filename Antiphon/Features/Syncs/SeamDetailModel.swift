import AntiphonDesign
import Foundation
import Observation

/// One seam: hero, health tiles, filter chips and its tracks.
@MainActor
@Observable
final class SeamDetailModel {
    enum Filter: Hashable { case all, toReview, new, missing }

    struct Tiles: Equatable {
        let inSync: Int
        let toReview: Int
        let unavailable: Int
    }

    let seamId: UUID
    private(set) var detail: SeamDetail?
    var filter: Filter = .all

    private let repository: SeamRepository

    init(seamId: UUID, repository: SeamRepository) {
        self.seamId = seamId
        self.repository = repository
    }

    func load() async {
        detail = (try? await repository.detail(for: seamId)) ?? detail
    }

    /// Opening a seam resets what counts as "New" next time.
    func markViewed() async {
        try? await repository.markViewed(seamId)
    }

    var tiles: Tiles {
        let counts = detail?.summary.counts ?? .empty
        return Tiles(inSync: counts.synced, toReview: counts.review, unavailable: counts.missing)
    }

    var chips: [ChipBar<Filter>.Chip] {
        let tracks = detail?.tracks ?? []
        return [
            .init(.all, "All", count: tracks.count),
            .init(.toReview, "To review", count: tracks.filter(Self.needsReview).count),
            .init(.new, "New", count: tracks.filter(\.isNew).count),
            .init(.missing, "Missing", count: tracks.filter(Self.isMissing).count)
        ]
    }

    var visibleTracks: [SeamTrack] {
        let tracks = detail?.tracks ?? []
        return switch filter {
        case .all: tracks
        case .toReview: tracks.filter(Self.needsReview)
        case .new: tracks.filter(\.isNew)
        case .missing: tracks.filter(Self.isMissing)
        }
    }

    /// "Spotify → Apple Music · watching about every 15 min"
    static func headerDetail(for seam: SeamSummary) -> String {
        let watch: String
        if seam.isPaused {
            watch = "paused"
        } else if seam.isMonitored && seam.monitorIntervalMinutes > 0 {
            watch = "watching about every \(RulesCopy.intervalPhrase(seam.monitorIntervalMinutes))"
        } else {
            watch = "syncs when you ask"
        }
        return "\(seam.directionText) · \(watch)"
    }

    private static func needsReview(_ track: SeamTrack) -> Bool {
        switch track.state {
        case .review, .removed: true
        default: false
        }
    }

    private static func isMissing(_ track: SeamTrack) -> Bool {
        if case .missing = track.state { return true }
        return false
    }
}
