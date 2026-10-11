import Foundation

/// Decides which entries of an Apple Music playlist to keep when removing
/// tracks. `MusicLibrary.edit(_:items:)` replaces the whole playlist, so this
/// refuses to proceed unless every entry was read.
enum PlaylistEntryEdit {

    /// One playlist entry, by every ID it's known under.
    struct Entry: Equatable, Sendable {
        /// Entry ID, library track ID and catalog ID, as available.
        let ids: Set<String>
        let isrc: String?
    }

    enum Failure: Error, Equatable {
        /// Fewer entries were read than the playlist holds; rewriting would truncate it.
        case incompleteRead(read: Int, expected: Int)
        /// None of the tracks to remove are in the playlist.
        case notFound
    }

    /// Entry indices in the order of `desired` (IDs as in `Entry.ids`).
    /// Entries `desired` doesn't name keep their relative order at the end,
    /// so a rewrite never drops one.
    static func orderedIndices(entries: [Entry], expectedCount: Int, desired: [String]) throws -> [Int] {
        guard entries.count == expectedCount else {
            throw Failure.incompleteRead(read: entries.count, expected: expectedCount)
        }
        var used = Set<Int>()
        var order: [Int] = []
        for id in desired {
            if let index = entries.indices.first(where: { !used.contains($0) && entries[$0].ids.contains(id) }) {
                used.insert(index)
                order.append(index)
            }
        }
        return order + entries.indices.filter { !used.contains($0) }
    }

    /// Indices of entries to keep, in order. Each track removes at most one
    /// entry, so an intentional duplicate survives.
    static func keptIndices(entries: [Entry], expectedCount: Int, removing tracks: [CatalogTrack]) throws -> [Int] {
        guard entries.count == expectedCount else {
            throw Failure.incompleteRead(read: entries.count, expected: expectedCount)
        }

        var removed = Set<Int>()
        for track in tracks {
            let isrc = track.isrc?.lowercased()
            let match = entries.indices.first { index in
                guard !removed.contains(index) else { return false }
                let entry = entries[index]
                if entry.ids.contains(track.id) { return true }
                if let isrc, let entryISRC = entry.isrc?.lowercased() { return isrc == entryISRC }
                return false
            }
            if let match { removed.insert(match) }
        }
        guard !removed.isEmpty else { throw Failure.notFound }
        return entries.indices.filter { !removed.contains($0) }
    }
}
