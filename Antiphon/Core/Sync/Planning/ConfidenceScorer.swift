import Foundation

/// Scores how likely two tracks are the same recording, from 0 to 100, and says why.
///
/// 100 is reserved for an ISRC match. Otherwise a match starts at 100 and loses
/// points for partial title or artist matches, a duration more than 2 s off,
/// an explicit/clean mismatch, and each kind of version difference (remaster,
/// live, remix…). Bands are applied separately by `ConfidencePolicy`.
enum ConfidenceScorer {

    static func score(source: CatalogTrack, candidate: CatalogTrack) -> MatchScore {
        if let a = realISRC(source.isrc), let b = realISRC(candidate.isrc), a == b {
            return MatchScore(confidence: 100, reason: .isrc)
        }

        let sourceTitle = VersionTag.parse(source.title)
        let candidateTitle = VersionTag.parse(candidate.title)
        let titleRelation = relation(sourceTitle.baseTitle, candidateTitle.baseTitle)
        let artistRelation = relation(source.artist.normalizedForMatching, candidate.artist.normalizedForMatching)

        guard titleRelation != .none else {
            return MatchScore(confidence: artistRelation == .equal ? 20 : 0, reason: .titleOnly)
        }
        guard artistRelation != .none else {
            return MatchScore(confidence: titleRelation == .equal ? 45 : 30, reason: .titleOnly)
        }

        var confidence = 100
        var isVersionDifference = false

        if titleRelation == .partial { confidence -= 20 }
        if artistRelation == .partial { confidence -= 10 }

        if let a = source.durationMs, let b = candidate.durationMs {
            let diff = abs(a - b)
            if diff > durationToleranceMs {
                let extraSeconds = Int((Double(diff - durationToleranceMs) / 1000).rounded(.up))
                confidence -= min(30, extraSeconds * 3)
                isVersionDifference = true
            }
        }

        if let a = source.isExplicit, let b = candidate.isExplicit, a != b {
            confidence -= explicitPenalty
            isVersionDifference = true
        }

        let differingKinds = Set(sourceTitle.tags.symmetricDifference(candidateTitle.tags).map(Kind.init))
        if !differingKinds.isEmpty {
            confidence -= differingKinds.reduce(0) { $0 + $1.penalty }
            isVersionDifference = true
        }

        return MatchScore(
            confidence: min(99, max(0, confidence)),
            reason: isVersionDifference ? .versionDifference : .titleArtistDuration
        )
    }

    // MARK: - Private

    private static let durationToleranceMs = 2000
    private static let explicitPenalty = 12

    private enum Relation { case equal, partial, none }

    private static func relation(_ a: String, _ b: String) -> Relation {
        if a == b { return a.isEmpty ? .none : .equal }
        guard !a.isEmpty, !b.isEmpty else { return .none }
        return a.contains(b) || b.contains(a) ? .partial : .none
    }

    private static func realISRC(_ isrc: String?) -> String? {
        guard let isrc, !isrc.isEmpty, !isrc.hasPrefix("local-") else { return nil }
        return isrc.lowercased()
    }

    /// Version tags grouped so two different remixes cost one remix penalty, not two.
    private enum Kind: Hashable {
        case remaster, live, radioEdit, acoustic, instrumental, demo, clean, remix

        init(_ tag: VersionTag) {
            switch tag {
            case .remaster: self = .remaster
            case .live: self = .live
            case .radioEdit: self = .radioEdit
            case .acoustic: self = .acoustic
            case .instrumental: self = .instrumental
            case .demo: self = .demo
            case .clean: self = .clean
            case .remix: self = .remix
            }
        }

        var penalty: Int {
            switch self {
            case .remaster: 12
            case .clean: 12
            case .radioEdit: 15
            case .acoustic, .demo: 40
            case .live, .remix: 45
            case .instrumental: 50
            }
        }
    }
}
