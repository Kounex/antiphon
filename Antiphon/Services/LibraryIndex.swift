import Foundation
import SwiftData

/// The tracks of every seam, for local search. Playlists that aren't in a
/// seam aren't indexed.
protocol TrackIndex: Sendable {
    func indexedTracks() async throws -> [IndexedTrack]
}

extension SwiftDataSeamRepository: TrackIndex {
    func indexedTracks() async throws -> [IndexedTrack] {
        let context = ModelContext(modelContainerForReview)
        return try context.fetch(FetchDescriptor<SyncPair>()).flatMap { pair in
            let name = pair.syncDirection == .appleToSpotify ? pair.appleMusicPlaylistName : pair.spotifyPlaylistName
            let seam = SeamRef(id: pair.id, name: name)
            return pair.cachedTracks.map { row in
                IndexedTrack(
                    title: row.title, artist: row.artist, album: row.albumName,
                    artworkURL: row.artworkURL.flatMap(URL.init(string:)), seam: seam,
                    onSpotify: row.spotifyTrackUri != nil && row.removalFlag != .removedFromSpotify,
                    onAppleMusic: row.appleMusicTrackId != nil && row.removalFlag != .removedFromAppleMusic
                )
            }
        }
    }
}

/// Checks which tracks of a playlist the other catalog has.
protocol AvailabilityService: Sendable {
    /// Calls `progress` with the report so far after each batch.
    func check(_ tracks: [CatalogTrack], on platform: Platform,
               progress: @escaping @Sendable (AvailabilityReport) async -> Void) async throws -> AvailabilityReport
}

/// The same matching syncs use. Apple Music lookups are batched by ISRC
/// first, so a Spotify playlist checks in a few requests; Spotify has no
/// batch lookup, so an Apple Music playlist costs one search per track.
struct LiveAvailabilityService: AvailabilityService {
    var preferences: AppPreferences = .shared

    func check(_ tracks: [CatalogTrack], on platform: Platform,
               progress: @escaping @Sendable (AvailabilityReport) async -> Void) async throws -> AvailabilityReport {
        var report = AvailabilityReport(total: tracks.count)
        let appleCatalog = AppleMusicTrackCatalog(manager: AppleMusicManager())
        let spotifyCatalog = SpotifyTrackCatalog(client: SpotifyAPIClient())
        if platform == .appleMusic {
            await appleCatalog.prefetch(isrcs: tracks.compactMap(\.isrc))
        }
        let policy = preferences.confidencePolicy
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let outcome: MatchOutcome? = switch platform {
            case .appleMusic: try? await MatchFinder.find(track, in: appleCatalog, targetPlaylist: [], preferences: preferences.versionPreferences)
            case .spotify: try? await MatchFinder.find(track, in: spotifyCatalog, targetPlaylist: [], preferences: preferences.versionPreferences)
            }
            let confidence = outcome?.best?.confidence ?? 0
            if confidence >= policy.autoAddThreshold {
                report.available.insert(track.id)
            } else if confidence >= ConfidencePolicy.reviewFloor {
                report.close.insert(track.id)
            } else {
                report.missing.insert(track.id)
            }
            report.checked = index + 1
            if index % 10 == 9 || index == tracks.count - 1 { await progress(report) }
        }
        return report
    }
}

#if DEBUG
extension PreviewSeamRepository: TrackIndex {
    func indexedTracks() async throws -> [IndexedTrack] {
        let drive = SeamRef(id: PreviewFixtures.lateNightDrive.id, name: "Late Night Drive")
        let garden = SeamRef(id: PreviewFixtures.gardenSundays.id, name: "Garden Sundays")
        let run = SeamRef(id: PreviewFixtures.runClub.id, name: "Run Club")
        func t(_ title: String, _ artist: String, _ album: String, _ seam: SeamRef, apple: Bool = true) -> IndexedTrack {
            IndexedTrack(title: title, artist: artist, album: album, artworkURL: nil, seam: seam, onSpotify: true, onAppleMusic: apple)
        }
        return [
            t("Running Up That Hill", "Kate Bush", "Hounds of Love", drive),
            t("Running Up That Hill", "Kate Bush", "Hounds of Love", run),
            t("Running Up That Hill", "Kate Bush", "Hounds of Love", garden, apple: false),
            t("Hill Country", "Midlake", "The Trials of Van Occupanther", garden, apple: false),
            t("Hills", "The Weeknd", "Beauty Behind the Madness", drive),
            t("Holocene", "Bon Iver", "Bon Iver, Bon Iver", garden),
            t("Nightcall", "Kavinsky", "OutRun", drive)
        ]
    }
}

/// Answers like the storyboard: 4 of a playlist's tracks aren't found.
struct PreviewAvailabilityService: AvailabilityService {
    func check(_ tracks: [CatalogTrack], on platform: Platform,
               progress: @escaping @Sendable (AvailabilityReport) async -> Void) async throws -> AvailabilityReport {
        var report = AvailabilityReport(total: tracks.count, checked: tracks.count)
        for (index, track) in tracks.enumerated() {
            if PreviewLibraryService.unavailableTitles.contains(track.title) || index >= 109 {
                report.missing.insert(track.id)
            } else {
                report.available.insert(track.id)
            }
        }
        await progress(report)
        return report
    }
}
#endif
