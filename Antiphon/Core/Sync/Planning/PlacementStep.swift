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

        /// A dry-run row: the track on its own side plus its counterpart.
        init(_ row: PlanRow) {
            let own = row.source.id
            self.init(key: "\(row.source.platform.rawValue):\(own)",
                      spotifyId: row.source.platform == .spotify ? own : row.counterpartId,
                      appleMusicId: row.source.platform == .appleMusic ? own : row.counterpartId)
        }
    }

    /// A track the step moved, for the run's log (undo puts it back).
    struct Moved: Sendable {
        let track: CatalogTrack
        let from: Int
        let to: Int
    }

    /// Reads both playlists and reorders `platform` if the placed rows aren't
    /// where they belong. Returns the tracks it moved.
    @discardableResult
    static func place(_ placing: Set<String>, on platform: Platform, playlistId: String, otherPlaylistId: String,
                      rows: [Row], editor: some PlaylistEditor) async throws -> [Moved] {
        guard !placing.isEmpty else { return [] }
        let target = try await editor.tracks(in: playlistId, on: platform)
        let reference = try await editor.tracks(in: otherPlaylistId, on: platform.other).map(\.id)
        guard let order = desiredIDs(target: target.map(\.id), reference: reference, rows: rows, placing: placing, on: platform) else {
            return []
        }
        try await editor.reorder(playlistId, on: platform, to: order)
        return moved(target, to: order)
    }

    /// "Same order": reads both playlists and reorders `platform` to follow
    /// the other side. Returns the tracks it moved.
    @discardableResult
    static func mirror(on platform: Platform, playlistId: String, otherPlaylistId: String,
                       rows: [Row], editor: some PlaylistEditor) async throws -> [Moved] {
        let target = try await editor.tracks(in: playlistId, on: platform)
        let reference = try await editor.tracks(in: otherPlaylistId, on: platform.other).map(\.id)
        guard let order = mirroredIDs(target: target.map(\.id), reference: reference, rows: rows, on: platform) else { return [] }
        try await editor.reorder(playlistId, on: platform, to: order)
        return moved(target, to: order)
    }

    private static func moved(_ target: [CatalogTrack], to order: [String]) -> [Moved] {
        TrackOrder.movedTracks(from: target.map(\.id), to: order).map { move in
            Moved(track: target[move.from], from: move.from, to: move.to)
        }
    }

    /// `target`'s IDs following `reference`'s order, or `nil` if they already do.
    static func mirroredIDs(target: [String], reference: [String], rows: [Row], on platform: Platform) -> [String]? {
        let keyed = Keyed(rows)
        let targetKeys = keyed.keys(target, on: platform)
        let idByKey = Dictionary(uniqueKeysWithValues: zip(targetKeys, target))
        let desired = TrackOrder.mirrored(target: targetKeys, reference: keyed.keys(reference, on: platform.other))
        guard desired != targetKeys else { return nil }
        return desired.compactMap { idByKey[$0] }
    }

    /// `target`'s IDs in the order they belong, or `nil` if already right.
    /// IDs go through the rows so both sides compare; tracks Antiphon
    /// doesn't know, and second copies, keep their own identity.
    static func desiredIDs(target: [String], reference: [String], rows: [Row], placing: Set<String>,
                           on platform: Platform) -> [String]? {
        let keyed = Keyed(rows)
        let targetKeys = keyed.keys(target, on: platform)
        let idByKey = Dictionary(uniqueKeysWithValues: zip(targetKeys, target))
        let desired = TrackOrder.desired(target: targetKeys, reference: keyed.keys(reference, on: platform.other),
                                         placing: Set(placing.map { "\($0)#0" }))
        guard desired != targetKeys else { return nil }
        return desired.compactMap { idByKey[$0] }
    }

    /// Platform IDs as row keys, so both sides compare. Tracks Antiphon
    /// doesn't know, and second copies, keep their own identity.
    private struct Keyed {
        var keyBySpotify: [String: String] = [:]
        var keyByApple: [String: String] = [:]

        init(_ rows: [Row]) {
            for row in rows {
                if let id = row.spotifyId { keyBySpotify[id] = row.key }
                if let id = row.appleMusicId { keyByApple[id] = row.key }
            }
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
    }
}
