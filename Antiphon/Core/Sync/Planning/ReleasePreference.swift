import Foundation

/// Picks the original release when several releases are equally good
/// matches — typically the same recording (same ISRC) on the original album
/// and on compilations.
///
/// Order: the source's own album, then not a compilation (unless the source
/// is on one), then the earliest release year.
enum ReleasePreference {

    /// Sort key for a release, higher is better: album match strength,
    /// then not a compilation (unless the source is one), then earlier year.
    static func rank(_ candidate: CatalogTrack, for source: CatalogTrack) -> (Int, Int, Int) {
        let sourceIsCompilation = source.album.map(isCompilation) ?? false
        let isComp = candidate.album.map(isCompilation) ?? false
        return (albumMatch(candidate, source), sourceIsCompilation || !isComp ? 1 : 0, -(candidate.releaseYear ?? 9999))
    }

    /// Whether `a` should be preferred over `b` for `source`, as releases.
    static func prefers(_ a: CatalogTrack, over b: CatalogTrack, for source: CatalogTrack) -> Bool {
        rank(a, for: source) > rank(b, for: source)
    }

    /// 3: the same album title. 2: the same album in another edition
    /// ("Meteora" for "Meteora (Bonus Edition)"). 0: a different album.
    static func albumMatch(_ candidate: CatalogTrack, _ source: CatalogTrack) -> Int {
        guard let a = candidate.album, let b = source.album else { return 0 }
        if collapse(a) == collapse(b) { return 3 }
        let x = baseAlbum(a), y = baseAlbum(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        return x == y || x.hasPrefix(y + " ") || y.hasPrefix(x + " ") ? 2 : 0
    }

    /// Kept for callers that only need yes/no.
    static func sameAlbum(_ candidate: CatalogTrack, _ source: CatalogTrack) -> Bool {
        albumMatch(candidate, source) > 0
    }

    private static let compilationMarkers = [
        "greatest hits", "best of", "the very best", "essentials", "anthology", "collection",
        "anthems", "now that's what i call", "hits of", "top hits", "100 hits", "the hits",
        "compilation", "playlist", "mixtape", "workout", "party"
    ]

    static func isCompilation(_ album: String) -> Bool {
        let title = album.lowercased()
        return compilationMarkers.contains { title.contains($0) }
    }

    private static func collapse(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The album title without edition words, normalized for matching.
    static func baseAlbum(_ album: String) -> String {
        VersionTag.parse(album).baseTitle
            .replacingOccurrences(of: #"\b(bonus|deluxe|expanded|anniversary|edition|version|remastered|remaster)\b"#,
                                  with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}
