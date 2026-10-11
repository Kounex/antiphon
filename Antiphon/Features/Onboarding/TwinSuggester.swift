import Foundation

/// The first scan: playlists that already have a twin on the other side.
/// Names are compared first; track overlap is fetched only for name
/// candidates, to keep the number of requests bounded.
enum TwinSuggester {
    /// Names at least this similar are candidates.
    static let nameThreshold = 0.5
    /// Pairs at least this much the same start checked.
    static let checkedOverlap = 0.6
    /// Overlap is fetched for at most this many pairs.
    static let maxOverlapFetches = 12

    struct Pair: Hashable, Sendable {
        let spotify: LibraryPlaylist
        let appleMusic: LibraryPlaylist
        var sameName: Bool { spotify.name.localizedCaseInsensitiveCompare(appleMusic.name) == .orderedSame }
    }

    struct Suggestion: Identifiable, Hashable, Sendable {
        let pair: Pair
        let title: String
        let detail: String
        let isChecked: Bool
        var id: String { "\(pair.spotify.id)|\(pair.appleMusic.id)" }
    }

    static func candidates(spotify: [LibraryPlaylist], appleMusic: [LibraryPlaylist], linked: Set<String>) -> [Pair] {
        let sources = spotify.filter { $0.blockedReason == nil && !linked.contains($0.id) }
        let targets = appleMusic.filter { $0.isEditable && !linked.contains($0.id) }
        var scored: [(pair: Pair, score: Double, order: Int)] = []
        for (order, source) in sources.enumerated() {
            for target in targets {
                let score = nameScore(source.name, target.name)
                if score >= nameThreshold { scored.append((Pair(spotify: source, appleMusic: target), score, order)) }
            }
        }
        var usedSpotify = Set<String>(), usedApple = Set<String>()
        return scored
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }
            .filter { candidate in
                guard !usedSpotify.contains(candidate.pair.spotify.id), !usedApple.contains(candidate.pair.appleMusic.id) else { return false }
                usedSpotify.insert(candidate.pair.spotify.id)
                usedApple.insert(candidate.pair.appleMusic.id)
                return true
            }
            .map(\.pair)
    }

    /// 0…1: shared words over all words, where a word that begins another
    /// ("run", "running") counts as shared.
    static func nameScore(_ a: String, _ b: String) -> Double {
        func words(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        let wa = Array(Set(words(a))), wb = Array(Set(words(b)))
        guard !wa.isEmpty, !wb.isEmpty else { return 0 }
        func related(_ x: String, _ y: String) -> Bool {
            x == y || (min(x.count, y.count) >= 3 && (x.hasPrefix(y) || y.hasPrefix(x)))
        }
        var claimed = Set<Int>()
        var shared = 0
        for word in wa {
            if let index = wb.indices.first(where: { !claimed.contains($0) && related(word, wb[$0]) }) {
                claimed.insert(index)
                shared += 1
            }
        }
        return Double(shared) / Double(wa.count + wb.count - shared)
    }

    static func suggestion(_ pair: Pair, shared: Int?, spotifyCount: Int, appleCount: Int) -> Suggestion {
        let title = pair.sameName ? pair.spotify.name : "\(pair.spotify.name) ↔ \(pair.appleMusic.name)"
        let names = pair.sameName ? "Same name" : "Different names"
        guard let shared else { return Suggestion(pair: pair, title: title, detail: names, isChecked: pair.sameName) }
        let overlap = Double(shared) / Double(max(1, spotifyCount, appleCount))
        return Suggestion(pair: pair, title: title, detail: "\(names) · \(Int((overlap * 100).rounded()))% same",
                          isChecked: overlap >= checkedOverlap)
    }

    static func headline(_ count: Int) -> String {
        switch count {
        case 0: "No twins found yet"
        case 1: "1 playlist already has a twin"
        default: "\(count) playlists already have a twin"
        }
    }

    static func restLine(spotify: Int, appleMusic: Int) -> String? {
        switch (spotify, appleMusic) {
        case (0, 0): return nil
        case (1, 0): return "1 other Spotify playlist has no twin. You can add it from Library."
        case (0, 1): return "1 other Apple Music playlist has no twin. You can add it from Library."
        case (_, 0): return "\(spotify) other Spotify playlists have no twin. You can add them from Library."
        case (0, _): return "\(appleMusic) other Apple Music playlists have no twin. You can add them from Library."
        default: return "\(spotify) other Spotify \(spotify == 1 ? "playlist" : "playlists") and \(appleMusic) on Apple Music have no twin. You can add them from Library."
        }
    }

    /// Twins hold tracks on both sides, so they're linked both ways. "Only
    /// add" becomes "ask before removing".
    static func removalPolicy(for choice: RemovalPolicy) -> RemovalPolicy {
        choice == .mirror ? .mirror : .ask
    }
}
