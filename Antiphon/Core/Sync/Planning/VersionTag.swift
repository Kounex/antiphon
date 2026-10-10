import Foundation

/// A difference between recordings of the same song that shows up in its title:
/// "(Remaster)", "- Live", "[Radio Edit]" and so on.
///
/// Only text in a version segment counts — parentheses, brackets, or a
/// " - " suffix — so a song called "Live Forever" carries no `.live` tag.
enum VersionTag: Hashable, Sendable {
    case remaster
    case live
    case radioEdit
    case acoustic
    case instrumental
    case demo
    case clean
    /// Keeps the remix's normalized label so two different remixes differ.
    case remix(String)

    struct Parsed: Equatable, Sendable {
        /// The title with version, credit and promo segments removed, normalized for matching.
        let baseTitle: String
        let tags: Set<VersionTag>
    }

    static func parse(_ title: String) -> Parsed {
        var remaining = title
        var tags = Set<VersionTag>()

        // " - suffix" first, so "Song - Blanke Remix" and "Song (Blanke Remix)" agree.
        if let dash = remaining.range(of: " - ") {
            let suffix = String(remaining[dash.upperBound...])
            switch classify(suffix) {
            case .tag(let tag):
                tags.insert(tag)
                remaining = String(remaining[..<dash.lowerBound])
            case .drop:
                remaining = String(remaining[..<dash.lowerBound])
            case .keep:
                break
            }
        }

        for regex in segmentRegexes {
            let matches = regex.matches(in: remaining, range: NSRange(remaining.startIndex..., in: remaining))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: remaining),
                      let inner = Range(match.range(at: 1), in: remaining) else { continue }
                switch classify(String(remaining[inner])) {
                case .tag(let tag):
                    tags.insert(tag)
                    remaining.removeSubrange(whole)
                case .drop:
                    remaining.removeSubrange(whole)
                case .keep:
                    break
                }
            }
        }

        return Parsed(baseTitle: remaining.normalizedForMatching, tags: tags)
    }

    // MARK: - Private

    private enum Classification {
        case tag(VersionTag)
        case drop
        case keep
    }

    private static let segmentRegexes: [NSRegularExpression] = [
        "\\(([^)]*)\\)",
        "\\[([^\\]]*)\\]"
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    private static let creditPrefixes = ["feat.", "feat ", "ft.", "ft ", "featuring", "with "]
    private static let junkWords = [
        "official", "video", "audio", "lyric", "visualizer", "explicit",
        "deluxe", "single version", "album version", "mono", "stereo", "hd", "hq"
    ]

    private static func classify(_ segment: String) -> Classification {
        let text = segment.lowercased().trimmingCharacters(in: .whitespaces)
        let words = Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))

        if creditPrefixes.contains(where: text.hasPrefix) { return .drop }
        if text.contains("remaster") { return .tag(.remaster) }
        if text.contains("radio edit") || text.contains("radio version") || text.contains("single edit") {
            return .tag(.radioEdit)
        }
        if text.contains("remix") || words.contains("mix") || words.contains("rework") {
            return .tag(.remix(segment.normalizedForMatching))
        }
        if words.contains("live") { return .tag(.live) }
        if words.contains("acoustic") { return .tag(.acoustic) }
        if words.contains("instrumental") { return .tag(.instrumental) }
        if words.contains("demo") { return .tag(.demo) }
        if words.contains("clean") { return .tag(.clean) }
        if junkWords.contains(where: { text.contains($0) }) { return .drop }
        return .keep
    }
}
