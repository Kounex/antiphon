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
        guard var batch = try await playlist.with([.tracks]).tracks else { return 0 }
        var count = batch.count
        while batch.hasNextBatch, let next = try await batch.nextBatch() {
            count += next.count
            batch = next
        }
        return count
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
