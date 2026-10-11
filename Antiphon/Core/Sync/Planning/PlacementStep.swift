import Foundation

/// After tracks are added, moves them next to the neighbours they have on the
/// other side (`TrackOrder`). Runs after the writes, so a failure here leaves
/// the tracks at the end and nothing is lost.
enum PlacementStep {
    /// What the step needs from a cache row, read before any await.
    struct Row: Sendable {
        let key: String
        let spotifyId: String?
        let appleMusicId: String?

        init(key: String, spotifyId: String?, appleMusicId: String?) {
            self.key = key
            self.spotifyId = spotifyId
            self.appleMusicId = appleMusicId
        }

        init(_ row: CachedTrack) {
            self.init(key: row.id.uuidString, spotifyId: row.spotifyTrackUri, appleMusicId: row.appleMusicTrackId)
        }
    }

    /// Reads both playlists and reorders `platform` if the placed rows aren't
    /// where they belong. Returns whether it wrote.
    @discardableResult
    static func place(_ placing: Set<String>, on platform: Platform, playlistId: String, otherPlaylistId: String,
                      rows: [Row], editor: some PlaylistEditor) async throws -> Bool {
        guard !placing.isEmpty else { return false }
        let target = try await editor.tracks(in: playlistId, on: platform).map(\.id)
        let reference = try await editor.tracks(in: otherPlaylistId, on: platform.other).map(\.id)
        guard let order = desiredIDs(target: target, reference: reference, rows: rows, placing: placing, on: platform) else {
            return false
        }
        try await editor.reorder(playlistId, on: platform, to: order)
        return true
    }

    /// `target`'s IDs in the order they belong, or `nil` if already right.
    /// IDs go through the rows so both sides compare; tracks Antiphon
    /// doesn't know, and second copies, keep their own identity.
    static func desiredIDs(target: [String], reference: [String], rows: [Row], placing: Set<String>,
                           on platform: Platform) -> [String]? {
        var keyBySpotify: [String: String] = [:]
        var keyByApple: [String: String] = [:]
        for row in rows {
            if let id = row.spotifyId { keyBySpotify[id] = row.key }
            if let id = row.appleMusicId { keyByApple[id] = row.key }
        }
        func keys(_ ids: [String], on platform: Platform) -> [String] {
            let lookup = platform == .spotify ? keyBySpotify : keyByApple
            var seen: [String: Int] = [:]
            return ids.map { id in
                let base = lookup[id] ?? "id:\(id)"
                let copy = seen[base, default: 0]
                seen[base] = copy + 1
                return "\(base)#\(copy)"
            }
        }
        let targetKeys = keys(target, on: platform)
        let idByKey = Dictionary(uniqueKeysWithValues: zip(targetKeys, target))
        let desired = TrackOrder.desired(target: targetKeys, reference: keys(reference, on: platform.other),
                                         placing: Set(placing.map { "\($0)#0" }))
        guard desired != targetKeys else { return nil }
        return desired.compactMap { idByKey[$0] }
    }
}
