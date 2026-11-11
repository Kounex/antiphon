import Foundation
import MusicKit

/// Apple Music adds songs by catalog ID, but playlist reads list library
/// IDs (`i.…`), and only some seconds later. Storing the library ID right
/// after a write lets the next sync tell a real removal from that delay.
enum LibraryAnchor {
    /// A song Antiphon just added, by catalog ID.
    struct Added: Equatable, Sendable {
        let catalogID: String
        let title: String
        let artist: String
        let durationMs: Int?
    }

    /// One entry of a playlist read.
    struct Entry: Equatable, Sendable {
        let libraryID: String
        let catalogID: String?
        let title: String
        let artist: String
        let durationMs: Int?
    }

    /// Catalog ID → library ID, for the added songs the playlist lists.
    ///
    /// Matches by catalog ID first. A song already in the person's library is
    /// listed under that entry's catalog ID, which can be an equivalent one
    /// (seen: added 1831584253, listed as 193613943), so the rest match by
    /// title, artist and length against entries no other song claimed.
    ///
    /// `before`: how often each library ID was in the playlist before the
    /// add. Those entries are never the added song. Without it, the fallback
    /// took the old version for the new one when a version pick's add
    /// wasn't listed yet (same title, artist and length), and the swap then
    /// removed the only copy (seen on the phone, 2026-11-11).
    static func libraryIDs(for added: [Added], in entries: [Entry], before: [String: Int] = [:]) -> [String: String] {
        var remaining = before
        let entries = entries.filter { entry in
            guard let count = remaining[entry.libraryID], count > 0 else { return true }
            remaining[entry.libraryID] = count - 1
            return false
        }
        var result: [String: String] = [:]
        var claimed = Set<String>()
        for song in added {
            if let entry = entries.first(where: { $0.catalogID == song.catalogID }) {
                result[song.catalogID] = entry.libraryID
                claimed.insert(entry.libraryID)
            }
        }
        // Entries listed under another added song's catalog ID belong to it.
        let addedIDs = Set(added.map(\.catalogID))
        for song in added where result[song.catalogID] == nil {
            let match = entries.first { entry in
                !claimed.contains(entry.libraryID)
                    && !(entry.catalogID.map(addedIDs.contains) ?? false)
                    && entry.title.normalizedForMatching == song.title.normalizedForMatching
                    && entry.artist.normalizedForMatching == song.artist.normalizedForMatching
                    && sameLength(entry.durationMs, song.durationMs)
            }
            if let match {
                result[song.catalogID] = match.libraryID
                claimed.insert(match.libraryID)
            }
        }
        return result
    }

    static func missing(_ added: [Added], from found: [String: String]) -> [Added] {
        added.filter { found[$0.catalogID] == nil }
    }

    private static func sameLength(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 2000
    }
}

extension AppleMusicManager {
    /// How often each library ID is in `playlist` now: read before an add,
    /// so anchoring can tell the new entries from the ones already there.
    func entryCounts(of playlist: Playlist) async -> [String: Int] {
        guard let tracks = try? await allTracks(of: playlist) else { return [:] }
        return tracks.reduce(into: [:]) { $0[$1.id.rawValue, default: 0] += 1 }
    }

    /// Reads `playlist` until it lists every added song (or the attempts run
    /// out) and returns catalog ID → library ID for those found. Never
    /// throws: anything not found keeps its catalog ID, and the next sync
    /// waits `DeltaEngine.appleMusicReadGrace` for it.
    func libraryIDs(for songs: [Song], in playlist: Playlist, before: [String: Int] = [:],
                    attempts: Int = 5, delay: Duration = .seconds(2)) async -> [String: String] {
        let added = songs.filter { !$0.id.rawValue.hasPrefix("i.") }.map {
            LibraryAnchor.Added(catalogID: $0.id.rawValue, title: $0.title, artist: $0.artistName,
                                durationMs: $0.duration.map { Int($0 * 1000) })
        }
        guard !added.isEmpty else { return [:] }
        var found: [String: String] = [:]
        var lastEntries: [LibraryAnchor.Entry] = []
        for attempt in 1...attempts {
            #if DEBUG
            print("[AppleMusic] Anchoring attempt \(attempt) of \(attempts)")
            #endif
            if let tracks = try? await allTracks(of: playlist) {
                lastEntries = tracks.map {
                    LibraryAnchor.Entry(libraryID: $0.id.rawValue, catalogID: Self.catalogID(for: $0), title: $0.title,
                                        artist: $0.artistName, durationMs: $0.duration.map { Int($0 * 1000) })
                }
                found = LibraryAnchor.libraryIDs(for: added, in: lastEntries, before: before)
            }
            if LibraryAnchor.missing(added, from: found).isEmpty { break }
            if attempt < attempts { try? await Task.sleep(for: delay) }
        }
        #if DEBUG
        print("[AppleMusic] Anchored \(found.count) of \(added.count) added songs to library IDs")
        let missing = LibraryAnchor.missing(added, from: found)
        if !missing.isEmpty {
            print("[AppleMusic] Not anchored: \(missing.map(\.catalogID)). Playlist entries: \(lastEntries.map { "\($0.title)=\($0.libraryID)/\($0.catalogID ?? "nil")" })")
        }
        #endif
        return found
    }
}
