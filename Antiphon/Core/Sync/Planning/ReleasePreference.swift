import Foundation

/// Picks the original release when several releases are equally good
/// matches — typically the same recording (same ISRC) on the original album
/// and on compilations.
///
/// Order: the source's own album, then not a compilation (unless the source
/// is on one), then the earliest release year.
enum ReleasePreference {

    /// Whether `a` should be preferred over `b` for `source`. Only consulted
    /// when both match equally well.
    static func prefers(_ a: CatalogTrack, over b: CatalogTrack, for source: CatalogTrack) -> Bool {
        let albumA = sameAlbum(a, source), albumB = sameAlbum(b, source)
        if albumA != albumB { return albumA }

        let sourceIsCompilation = source.album.map(isCompilation) ?? false
        if !sourceIsCompilation {
            let compA = a.album.map(isCompilation) ?? false
            let compB = b.album.map(isCompilation) ?? false
            if compA != compB { return !compA }
        }

        switch (a.releaseYear, b.releaseYear) {
        case let (x?, y?) where x != y: return x < y
        case (.some, nil): return true
        default: return false
        }
    }

    /// Album titles match once edition suffixes are stripped
    /// ("Hybrid Theory (Bonus Edition)" ~ "Hybrid Theory").
    static func sameAlbum(_ candidate: CatalogTrack, _ source: CatalogTrack) -> Bool {
        guard let a = candidate.album, let b = source.album else { return false }
        let x = baseAlbum(a), y = baseAlbum(b)
        return !x.isEmpty && (x == y || x.hasPrefix(y) || y.hasPrefix(x))
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

    private static func baseAlbum(_ album: String) -> String {
        VersionTag.parse(album).baseTitle
            .replacingOccurrences(of: #"\b(bonus|deluxe|expanded|anniversary|edition|version|remastered|remaster)\b"#,
                                  with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}
