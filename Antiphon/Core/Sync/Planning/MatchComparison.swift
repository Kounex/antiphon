import Foundation

/// The evidence behind a match, field by field.
enum MatchComparison {
    struct Row: Equatable, Sendable {
        let label: String
        let left: String
        let right: String
        let differs: Bool
        var isCode: Bool = false
    }

    static func rows(source: CatalogTrack, candidate: CatalogTrack) -> [Row] {
        [
            Row(label: "Title", left: source.title, right: candidate.title,
                differs: collapse(source.title) != collapse(candidate.title)),
            Row(label: "Artist", left: source.artist, right: candidate.artist,
                differs: source.artist.normalizedForMatching != candidate.artist.normalizedForMatching),
            Row(label: "Album", left: source.album ?? dash, right: candidate.album ?? dash,
                differs: known(source.album, candidate.album).map { collapse($0) != collapse($1) } ?? false),
            Row(label: "Length", left: length(source.durationMs), right: length(candidate.durationMs),
                differs: known(source.durationMs, candidate.durationMs).map { abs($0 - $1) > 2000 } ?? false),
            Row(label: "Explicit", left: yesNo(source.isExplicit), right: yesNo(candidate.isExplicit),
                differs: known(source.isExplicit, candidate.isExplicit).map { $0 != $1 } ?? false),
            Row(label: "ISRC", left: source.isrc ?? dash, right: candidate.isrc ?? dash,
                differs: known(source.isrc, candidate.isrc).map { $0.lowercased() != $1.lowercased() } ?? false, isCode: true)
        ]
    }

    static let dash = "–"

    static func length(_ ms: Int?) -> String {
        guard let ms else { return dash }
        let seconds = ms / 1000
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    private static func yesNo(_ value: Bool?) -> String {
        value.map { $0 ? "Yes" : "No" } ?? dash
    }

    private static func known<T>(_ a: T?, _ b: T?) -> (T, T)? {
        guard let a, let b else { return nil }
        return (a, b)
    }

    private static func collapse(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
