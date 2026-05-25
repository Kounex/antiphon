import Foundation

extension String {
    private static let normalizationRegexes: [NSRegularExpression] = {
        let patterns = [
            "\\s*\\(remaster(ed)?\\)",
            "\\s*\\(deluxe( edition)?\\)",
            "\\s*\\(feat\\..+?\\)",
            "\\s*\\(ft\\..+?\\)",
            "\\s*\\(featuring.+?\\)",
            "\\s*\\(with.+?\\)",
            "\\s*-\\s*remaster(ed)?.*$",
            "\\s*-\\s*single.*$",
            "\\s*-\\s*live.*$",
            "\\s*\\[(official)?\\s*(video|audio|music video|lyric video|visualizer|hd|sd|hq|explicit)\\]",
            "\\s*\\((official)?\\s*(video|audio|music video|lyric video|visualizer|hd|sd|hq|explicit)\\)"
        ]
        return patterns.compactMap { try? NSRegularExpression(pattern: $0, options: .caseInsensitive) }
    }()

    /// Normalizes a track title for fuzzy matching by stripping common suffixes
    /// such as "(Remastered)", "(Deluxe Edition)", "(feat. …)", and bracketed tags.
    ///
    /// This is used as a fallback when ISRC matching fails and the sync engine
    /// needs to compare track metadata across platforms.
    var normalizedForMatching: String {
        var result = self.lowercased()

        // 1. Strip feature tags, remaster, deluxe, live, single, and junk video/audio tags
        for regex in Self.normalizationRegexes {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // 2. Replace hyphens, slashes, and backslashes with spaces
        result = result
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "/", with: " ")
            .replacingOccurrences(of: "\\", with: " ")

        // 3. Remove parenthesis, bracket, brace wrapper characters and punctuation
        let charsToRemove: Set<Character> = ["(", ")", "[", "]", "{", "}", ",", ".", "'", "\"", "’", "`"]
        result = String(result.filter { !charsToRemove.contains($0) })

        // 4. Collapse multiple spaces and trim
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
