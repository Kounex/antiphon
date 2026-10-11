import Foundation
import MusicKit

/// Removing tracks from an Apple Music playlist via `MusicLibrary.edit(_:items:)`.
///
/// Verified on a device for playlists Antiphon created (D1). `edit` replaces
/// the playlist's items, so every entry is read (all pages) and cross-checked
/// against the track count before anything is written.
extension AppleMusicManager {

    func removeTracks(_ tracks: [CatalogTrack], from playlist: Playlist) async throws {
        guard MusicAuthorization.currentStatus == .authorized else { throw AppleMusicError.notAuthorized }

        let entries = try await allEntries(of: playlist)
        let trackCount = try await allTrackCount(of: playlist)
        let kept = try PlaylistEntryEdit.keptIndices(
            entries: entries.map(Self.identity),
            expectedCount: trackCount,
            removing: tracks
        )
        _ = try await MusicLibrary.shared.edit(playlist, items: kept.map { entries[$0] })
    }

    /// Rewrites the playlist in `order` (library or catalog IDs). Entries
    /// `order` doesn't name stay, at the end. Only for playlists Antiphon
    /// created (D1).
    func reorderTracks(in playlist: Playlist, to order: [String]) async throws {
        guard MusicAuthorization.currentStatus == .authorized else { throw AppleMusicError.notAuthorized }
        let entries = try await allEntries(of: playlist)
        let indices = try PlaylistEntryEdit.orderedIndices(
            entries: entries.map(Self.identity),
            expectedCount: try await allTrackCount(of: playlist),
            desired: order
        )
        guard indices != Array(entries.indices) else { return }
        _ = try await MusicLibrary.shared.edit(playlist, items: indices.map { entries[$0] })
    }

    /// Every track in `playlist`, following further batches if MusicKit
    /// returns the relationship in pages. `nil` when it has no tracks
    /// relationship.
    func allTracks(of playlist: Playlist) async throws -> [Track]? {
        guard var batch = try await playlist.with([.tracks]).tracks else { return nil }
        var all = Array(batch)
        var pages = 1
        // An empty batch ends it too, so a relationship that keeps claiming
        // more can't loop forever.
        while batch.hasNextBatch, let next = try await batch.nextBatch(), !next.isEmpty {
            all.append(contentsOf: next)
            batch = next
            pages += 1
        }
        #if DEBUG
        if pages > 1 { print("[AppleMusic] Read \(all.count) tracks of \(playlist.name) in \(pages) batches") }
        #endif
        return all
    }

    // MARK: - Private

    private func allEntries(of playlist: Playlist) async throws -> [Playlist.Entry] {
        guard var batch = try await playlist.with([.entries]).entries else { return [] }
        var all = Array(batch)
        while batch.hasNextBatch, let next = try await batch.nextBatch() {
            all.append(contentsOf: next)
            batch = next
        }
        return all
    }

    private func allTrackCount(of playlist: Playlist) async throws -> Int {
        try await allTracks(of: playlist)?.count ?? 0
    }

    /// Every ID an entry is known under: entry, library item and catalog.
    private nonisolated static func identity(_ entry: Playlist.Entry) -> PlaylistEntryEdit.Entry {
        var ids: Set<String> = [entry.id.rawValue]
        switch entry.item {
        case .song(let song): ids.insert(song.id.rawValue)
        case .musicVideo(let video): ids.insert(video.id.rawValue)
        default: break
        }
        if let playParameters = entry.playParameters,
           let data = try? JSONEncoder().encode(playParameters),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for key in ["catalogId", "id"] {
                if let value = json[key] as? String, !value.isEmpty { ids.insert(value) }
            }
        }
        return PlaylistEntryEdit.Entry(ids: ids, isrc: entry.isrc)
    }
}
