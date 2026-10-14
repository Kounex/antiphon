import Foundation

/// Picks the original release when several releases are equally good
/// matches — typically the same recording (same ISRC) on the original album
/// and on compilations.
///
/// `.sourceAlbum` order: the source's own album, then not a compilation
/// (unless the source is on one), then the earliest release year.
/// `.original` order: a studio album, the earliest year, an album over a
/// single, the standard edition, then the source's album.
enum ReleasePreference {

    /// Sort key for a release, higher is better.
    static func rank(_ candidate: CatalogTrack, for source: CatalogTrack,
                     choice: ReleaseChoice = .sourceAlbum) -> (Int, Int, Int, Int, Int) {
        let album = candidate.album ?? ""
        let notCompilation = isCompilation(candidate) ? 0 : 1
        let earlier = -(candidate.releaseYear ?? 9999)
        switch choice {
        case .sourceAlbum:
            let sourceIsCompilation = isCompilation(source)
            return (albumMatch(candidate, source), sourceIsCompilation ? 1 : notCompilation, earlier, 0, 0)
        case .original:
            // A studio album wins; otherwise whatever came first, where a
            // compilation beats a single from the same year.
            let notSingle = isSingle(candidate) ? 0 : 1
            return (notCompilation * notSingle, earlier, notSingle, isSpecialEdition(album) ? 0 : 1,
                    albumMatch(candidate, source))
        }
    }

    /// Whether `a` should be preferred over `b` for `source`, as releases.
    static func prefers(_ a: CatalogTrack, over b: CatalogTrack, for source: CatalogTrack,
                        choice: ReleaseChoice = .sourceAlbum) -> Bool {
        rank(a, for: source, choice: choice) > rank(b, for: source, choice: choice)
    }

    /// 3: the same album title. 2: the same album in another edition
    /// ("Meteora" for "Meteora (Bonus Edition)"). 0: a different album.
    static func albumMatch(_ candidate: CatalogTrack, _ source: CatalogTrack) -> Int {
        guard let a = candidate.album, let b = source.album else { return 0 }
        if asWritten(a) == asWritten(b) { return 3 }
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

    /// The catalog's album type, or else the title.
    static func isCompilation(_ track: CatalogTrack) -> Bool {
        track.albumKind == .compilation || isCompilation(track.album ?? "")
    }

    static func isSingle(_ track: CatalogTrack) -> Bool {
        track.albumKind == .single || isSingle(track.album ?? "")
    }

    static func isStudioAlbum(_ track: CatalogTrack) -> Bool {
        !isCompilation(track) && !isSingle(track)
    }

    static func isCompilation(_ album: String) -> Bool {
        let title = album.lowercased()
        return compilationMarkers.contains { title.contains($0) }
    }

    /// Deluxe, anniversary, remastered and similar editions.
    static func isSpecialEdition(_ album: String) -> Bool {
        album.lowercased().range(of: #"\b(deluxe|expanded|bonus|anniversary|edition|remaster(ed)?|special|collector'?s|super)\b"#,
                                 options: .regularExpression) != nil
    }

    /// Apple Music names singles and EPs "… - Single" and "… - EP".
    static func isSingle(_ album: String) -> Bool {
        album.lowercased().range(of: #"\s-\s(single|ep)$"#, options: .regularExpression) != nil
    }

    /// The title as written, without punctuation or Apple's " - Single" /
    /// " - EP": Spotify's "Word Up! (The Remixes)" is Apple's "Word Up!: The Remixes - EP".
    private static func asWritten(_ album: String) -> String {
        album.lowercased()
            .replacingOccurrences(of: #"\s-\s(single|ep)$"#, with: "", options: .regularExpression)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }

    /// The album title without edition words, normalized for matching.
    static func baseAlbum(_ album: String) -> String {
        VersionTag.parse(album).baseTitle
            .replacingOccurrences(of: #"\b(bonus|deluxe|expanded|anniversary|edition|version|remastered|remaster)\b"#,
                                  with: "", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }
}
