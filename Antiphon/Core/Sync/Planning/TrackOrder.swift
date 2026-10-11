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

    /// `target` with the tracks it shares with `reference` in the reference's
    /// order. Tracks only on the target keep their slot. IDs are unique.
    static func mirrored(target: [String], reference: [String]) -> [String] {
        let shared = Set(target).intersection(reference)
        var next = reference.filter(shared.contains).makeIterator()
        return target.map { shared.contains($0) ? next.next() ?? $0 : $0 }
    }

    /// A track whose position a reorder changed.
    struct MovedTrack: Equatable, Sendable {
        let id: String
        let from: Int
        let to: Int
    }

    /// The tracks a reorder from `before` to `after` (same items) moved, in
    /// their new order. Tracks that only shifted because others moved past
    /// them aren't listed: the longest run that kept its relative order
    /// stays, everything else moved. Copies are told apart by occurrence.
    static func movedTracks(from before: [String], to after: [String]) -> [MovedTrack] {
        var positions: [String: [Int]] = [:]
        for (index, id) in before.enumerated() { positions[id, default: []].append(index) }
        var origins: [Int] = []   // each `after` slot's index in `before`, or -1
        for id in after {
            if let from = positions[id]?.first { positions[id]?.removeFirst(); origins.append(from) } else { origins.append(-1) }
        }
        let kept = longestIncreasing(origins.enumerated().filter { $0.element >= 0 }.map(\.offset), by: origins)
        return origins.enumerated().compactMap { index, from in
            from >= 0 && !kept.contains(index) ? MovedTrack(id: after[index], from: from, to: index) : nil
        }
    }

    /// Indices (from `candidates`) of a longest subsequence whose `values`
    /// increase. Patience sorting, O(n log n).
    private static func longestIncreasing(_ candidates: [Int], by values: [Int]) -> Set<Int> {
        var tails: [Int] = []          // candidate index ending each pile
        var previous: [Int: Int] = [:]
        for candidate in candidates {
            var low = 0, high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < values[candidate] { low = mid + 1 } else { high = mid }
            }
            if low > 0 { previous[candidate] = tails[low - 1] }
            if low == tails.count { tails.append(candidate) } else { tails[low] = candidate }
        }
        var result = Set<Int>()
        var current = tails.last
        while let index = current {
            result.insert(index)
            current = previous[index]
        }
        return result
    }

    /// `current` with each moved track back at its old index; everything else
    /// fills the other slots in its current order. `nil` when a moved track is
    /// gone or the indices don't fit.
    static func restoring(_ current: [String], moving: [(id: String, to: Int)]) -> [String]? {
        var rest = current
        var slots = [String?](repeating: nil, count: current.count)
        for (id, index) in moving {
            guard current.indices.contains(index), slots[index] == nil,
                  let position = rest.firstIndex(of: id) else { return nil }
            rest.remove(at: position)
            slots[index] = id
        }
        var others = rest.makeIterator()
        return slots.map { $0 ?? others.next() ?? "" }
    }

    /// The whole playlist in `order`: the slots that hold the ordered tracks
    /// get them in sequence, and every other item (podcast episodes,
    /// unavailable items) stays where it is. Spotify counts positions over
    /// all items, so moves must be worked out on this full list.
    /// `nil` when `order` names tracks the playlist doesn't hold (as often).
    static func fillingTrackSlots(_ items: [String], with order: [String]) -> [String]? {
        let ordered = Set(order)
        let tracks = items.filter { ordered.contains($0) }
        guard tracks.sorted() == order.sorted() else { return nil }
        var next = order.makeIterator()
        return items.map { ordered.contains($0) ? next.next() ?? $0 : $0 }
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
