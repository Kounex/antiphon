import Foundation
import SwiftData

/// A version the person picked for one song in one seam. Plans use it
/// instead of looking the song up, so Antiphon never matches it again.
@Model
final class PinnedMatch {
    @Attribute(.unique) var id: UUID
    /// The song on its own side, as planning keys it.
    var sourcePlatform: Platform
    var sourceId: String
    /// The picked version, on the other side.
    var trackData: Data
    var pinnedAt: Date

    var syncPair: SyncPair?

    init(key: TrackKey, track: CatalogTrack, pinnedAt: Date = Date()) {
        self.id = UUID()
        self.sourcePlatform = key.platform
        self.sourceId = key.id
        self.trackData = (try? JSONEncoder().encode(track)) ?? Data()
        self.pinnedAt = pinnedAt
    }

    var key: TrackKey { TrackKey(platform: sourcePlatform, id: sourceId) }

    var track: CatalogTrack? { try? JSONDecoder().decode(CatalogTrack.self, from: trackData) }

    /// Points the pin at another version.
    func update(to track: CatalogTrack) {
        trackData = (try? JSONEncoder().encode(track)) ?? trackData
        pinnedAt = Date()
    }
}

extension SyncPair {
    /// The person's picks, by song.
    var pinnedTracks: [TrackKey: CatalogTrack] {
        Dictionary(pins.compactMap { pin in pin.track.map { (pin.key, $0) } }, uniquingKeysWith: { _, latest in latest })
    }
}

/// Plans songs with a pick from the pick: certain, and no lookup.
enum PinnedPlanning {
    struct Split {
        /// Outcomes for the songs with a pick.
        let outcomes: [TrackKey: MatchOutcome]
        /// The rest, still to look up.
        let toLookUp: [PlanRow]
    }

    static func split(_ rows: [PlanRow], pins: [TrackKey: CatalogTrack], targetPlaylists: [Platform: [CatalogTrack]]) -> Split {
        var outcomes: [TrackKey: MatchOutcome] = [:]
        var toLookUp: [PlanRow] = []
        for row in rows {
            guard let pick = pins[row.key] else { toLookUp.append(row); continue }
            outcomes[row.key] = outcome(for: pick, targetPlaylist: targetPlaylists[row.source.platform.other] ?? [])
        }
        return Split(outcomes: outcomes, toLookUp: toLookUp)
    }

    static func outcome(for pick: CatalogTrack, targetPlaylist: [CatalogTrack]) -> MatchOutcome {
        MatchOutcome(best: MatchCandidate(track: pick, confidence: 100, reason: .manual), alternatives: [],
                     alreadyInTarget: targetPlaylist.contains { MatchFinder.isSameRecording(pick, $0) })
    }
}
