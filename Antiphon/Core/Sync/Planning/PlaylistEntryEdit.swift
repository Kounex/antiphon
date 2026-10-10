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
