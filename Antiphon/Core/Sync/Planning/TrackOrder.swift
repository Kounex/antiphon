import Foundation

/// Where tracks Antiphon adds belong in the target playlist.
///
/// New tracks are added at the end first, then placed: each one goes right
/// after the nearest track that comes before it on the other side and is
/// also on this side. Everything else keeps its place, so a person's own
/// order on this side is never rearranged.
enum TrackOrder {

    /// One Spotify reorder: move `rangeLength` items from `rangeStart` so
    /// they sit before the item now at `insertBefore`.
    struct Move: Equatable, Sendable {
        let rangeStart: Int
        let rangeLength: Int
        let insertBefore: Int
    }

    /// `target` with the `placing` items moved after their neighbours from
    /// `reference`. IDs are unique within each list.
    static func desired(target: [String], reference: [String], placing: Set<String>) -> [String] {
        let present = Set(target)
        var result = target.filter { !placing.contains($0) }
        var placed = Set<String>()
        for (index, id) in reference.enumerated() where placing.contains(id) && present.contains(id) {
            var insertAt = 0
            for previous in reference[..<index].reversed() {
                if let position = result.firstIndex(of: previous) {
                    insertAt = position + 1
                    break
                }
            }
            result.insert(id, at: insertAt)
            placed.insert(id)
        }
        // Not on the other side at all: they stay where they were added.
        result += target.filter { placing.contains($0) && !placed.contains($0) }
        return result
    }

    /// Moves that turn `current` into `desired` (same items, other order).
    /// Each move brings the next out-of-place run forward.
    static func moves(from current: [String], to desired: [String]) -> [Move] {
        var list = current
        var moves: [Move] = []
        var index = 0
        while index < desired.count {
            guard index < list.count else { break }
            if list[index] == desired[index] { index += 1; continue }
            guard let start = list[index...].firstIndex(of: desired[index]) else { break }
            var length = 1
            while start + length < list.count, index + length < desired.count,
                  list[start + length] == desired[index + length] {
                length += 1
            }
            let move = Move(rangeStart: start, rangeLength: length, insertBefore: index)
            moves.append(move)
            list = apply([move], to: list)
            index += length
        }
        return moves
    }

    /// What Spotify does with `moves`, for checking them.
    static func apply(_ moves: [Move], to list: [String]) -> [String] {
        var list = list
        for move in moves {
            let range = move.rangeStart..<(move.rangeStart + move.rangeLength)
            let items = Array(list[range])
            list.removeSubrange(range)
            let before = move.insertBefore > move.rangeStart ? move.insertBefore - move.rangeLength : move.insertBefore
            list.insert(contentsOf: items, at: before)
        }
        return list
    }
}
