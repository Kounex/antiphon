import Foundation

/// How two playlists overlap, for the Compare step.
struct Overlap: Sendable, Equatable {
    var sourceOnly: [CatalogTrack]
    var both: [CatalogTrack]
    var targetOnly: [CatalogTrack]

    /// ISRC first, then the same title, artist and length.
    static func compute(source: [CatalogTrack], target: [CatalogTrack]) -> Overlap {
        var unmatchedTarget = target
        var sourceOnly: [CatalogTrack] = []
        var both: [CatalogTrack] = []
        var targetByISRC: [String: Int] = [:]
        for (index, track) in target.enumerated() {
            if let isrc = track.isrc?.lowercased(), !isrc.hasPrefix("local-") { targetByISRC[isrc] = targetByISRC[isrc] ?? index }
        }
        var claimed = Set<Int>()

        for track in source {
            var match: Int?
            if let isrc = track.isrc?.lowercased(), let index = targetByISRC[isrc], !claimed.contains(index) {
                match = index
            } else {
                match = target.indices.first { !claimed.contains($0) && MatchFinder.isSameRecording(track, target[$0]) }
            }
            if let match {
                claimed.insert(match)
                both.append(track)
            } else {
                sourceOnly.append(track)
            }
        }
        unmatchedTarget = target.indices.filter { !claimed.contains($0) }.map { target[$0] }
        return Overlap(sourceOnly: sourceOnly, both: both, targetOnly: unmatchedTarget)
    }

    func accessibilityLabel(sourceName: String, targetName: String) -> String {
        "\(sourceOnly.count) only on \(sourceName), \(both.count) on both, \(targetOnly.count) only on \(targetName)"
    }
}

/// Ranks possible twins: most shared tracks first, then the closest name.
enum TwinRanker {
    struct Candidate: Sendable {
        let playlist: LibraryPlaylist
        /// Tracks already shared with the source, if fetched.
        let shared: Int?
    }

    struct Suggestion: Identifiable, Sendable {
        let playlist: LibraryPlaylist
        let shared: Int?
        let isSuggested: Bool
        var id: String { playlist.id }
    }

    static func rank(source: LibraryPlaylist, candidates: [Candidate]) -> [Suggestion] {
        let sorted = candidates.sorted { a, b in
            switch (a.shared, b.shared) {
            case let (x?, y?) where x != y: return x > y
            case (.some(let x), nil) where x > 0: return true
            case (nil, .some(let y)) where y > 0: return false
            default: return nameSimilarity(source.name, a.playlist.name) > nameSimilarity(source.name, b.playlist.name)
            }
        }
        return sorted.enumerated().map { index, candidate in
            Suggestion(playlist: candidate.playlist, shared: candidate.shared,
                       isSuggested: index == 0 && ((candidate.shared ?? 0) > 0 || nameSimilarity(source.name, candidate.playlist.name) == 1))
        }
    }

    /// 0…1: shared words over all words, case-insensitive.
    static func nameSimilarity(_ a: String, _ b: String) -> Double {
        let wa = Set(a.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        let wb = Set(b.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        guard !wa.isEmpty || !wb.isEmpty else { return 0 }
        return Double(wa.intersection(wb).count) / Double(wa.union(wb).count)
    }
}

/// Playlists picked together, set up one at a time.
struct NewSeamQueue: Sendable {
    let sources: [LibraryPlaylist]
    private(set) var index = 0

    init(sources: [LibraryPlaylist]) { self.sources = sources }

    var current: LibraryPlaylist? { sources.indices.contains(index) ? sources[index] : nil }
    var next: LibraryPlaylist? { sources.indices.contains(index + 1) ? sources[index + 1] : nil }
    var isFinished: Bool { index >= sources.count }
    var positionText: String { "\(min(index + 1, sources.count)) of \(sources.count)" }

    mutating func advance() { index += 1 }
}

enum NewSeamCopy {
    /// Recounts what will happen, in tracks.
    static func consequence(direction: SyncDirection, sourceName: String, targetName: String,
                            addsToTarget: Int, addsToSource: Int) -> String {
        if direction == .bidirectional {
            let adds: String
            switch (addsToTarget, addsToSource) {
            case (0, 0): adds = "Nothing to add yet."
            case (_, 0): adds = "Adds \(PlanCopy.count(addsToTarget, "track")) to \(targetName)."
            case (0, _): adds = "Adds \(PlanCopy.count(addsToSource, "track")) to \(sourceName)."
            default: adds = "Adds \(PlanCopy.count(addsToTarget, "track")) to \(targetName) and \(addsToSource) to \(sourceName)."
            }
            return "\(adds) From then on, anything you add on either side shows up on the other."
        }
        let adds = addsToTarget == 0 ? "Nothing to add yet." : "Adds \(PlanCopy.count(addsToTarget, "track")) to \(targetName)."
        return "\(adds) From then on, tracks you add to \(sourceName) are copied over. Nothing is removed."
    }

    static func doneTitle(name: String) -> String { "\(name) is stitched" }

    static func doneBody(added: Int, monitoring: Bool, interval: Int) -> String {
        let first = "\(PlanCopy.count(added, "track")) added."
        guard monitoring, interval > 0 else { return "\(first) Antiphon syncs this seam when you ask." }
        return "\(first) Antiphon now watches both playlists, about every \(RulesCopy.intervalPhrase(interval))."
    }
}

/// "about 40 s left", from the pace so far.
enum SyncETA {
    static func text(done: Int, total: Int, elapsed: TimeInterval) -> String? {
        guard done >= 3, done < total, elapsed > 0 else { return nil }
        let remaining = Double(total - done) * elapsed / Double(done)
        switch remaining {
        case ..<10: return "a few seconds left"
        case ..<60: return "about \(Int((remaining / 10).rounded()) * 10) s left"
        default: return "about \(Int((remaining / 60).rounded())) min left"
        }
    }
}
