import CryptoKit
import Foundation

/// Whether a background check can stop after one cheap look.
///
/// Reading a Spotify playlist costs a request per 50 tracks, twice per run
/// (plan, then apply). Spotify also gives every playlist a snapshot ID that
/// changes whenever the playlist does, for one small request. Apple Music's
/// track list is read from the library on the phone. So when a run ends
/// with nothing written and nothing waiting, it leaves a token: Spotify's
/// snapshot, the Apple Music track IDs in order, and the rules it ran
/// under. As long as the next look gives the same token, nothing can have
/// changed and the full read is skipped.
///
/// Spotify's snapshot can lag a change by a moment (measured on the phone
/// with the `monitor` self-test). That only ever delays a scheduled check
/// to the next one, so only scheduled background runs take the cheap look;
/// a run the person asks for reads everything.
///
/// Every doubt goes the safe way: a missing or different token, a row that
/// still needs work, or a song Apple Music doesn't list means a full check.
enum UnchangedCheck {
    /// What the check needs to know about one stored track.
    struct Row: Sendable {
        let state: TrackSyncState
        let appleMusicId: String?
        let removalFlag: RemovalFlag?
        let retryCount: Int
        let lastAttempt: Date?
    }

    static func token(spotifySnapshot: String, appleMusicIds: [String], rules: String) -> String {
        let digest = SHA256.hash(data: Data(appleMusicIds.joined(separator: "\n").utf8))
        let hash = digest.map { String(format: "%02x", $0) }.joined()
        return "v1|\(spotifySnapshot)|\(appleMusicIds.count):\(hash)|\(rules)"
    }

    static func canSkip(stored: String?, live: String, rows: [Row], liveAppleIds: Set<String>,
                        recheck: RecheckCadence, now: Date) -> Bool {
        guard let stored, stored == live else { return false }
        for row in rows {
            switch row.state {
            case .pending, .syncing:
                return false
            case .failed where AvailabilityRecheck.isDue(retryCount: row.retryCount, lastAttempt: row.lastAttempt, cadence: recheck, now: now):
                return false
            default:
                break
            }
            // In the playlist by the store's account, but Apple Music doesn't
            // list it: the engine may have to re-anchor or add it again.
            if row.removalFlag == nil, let id = row.appleMusicId, !liveAppleIds.contains(id) { return false }
        }
        return true
    }
}

extension UnchangedCheck.Row {
    init(_ track: CachedTrack) {
        self.init(state: track.effectiveSyncState, appleMusicId: track.appleMusicTrackId, removalFlag: track.removalFlag,
                  retryCount: track.retryCount, lastAttempt: track.lastSyncAttempt)
    }
}
