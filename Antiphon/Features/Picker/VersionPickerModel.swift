import Foundation
import Observation

/// One song in one seam, and what the other playlist holds for it now.
struct PickTarget: Identifiable, Hashable, Sendable {
    enum Current: Hashable, Sendable {
        case antiphonsPick(CatalogTrack)
        case yourPick(CatalogTrack)
        case notThere
    }

    let seam: SeamSummary
    /// The song on its own side.
    let source: CatalogTrack
    var current: Current
    /// The matcher's own candidates, best first.
    var candidates: [MatchCandidate] = []

    var key: TrackKey { TrackKey(source) }
    var id: TrackKey { key }
    /// The side the version goes to: the one the song didn't come from.
    var target: Platform { source.platform.other }

    var currentTrack: CatalogTrack? {
        switch current {
        case .antiphonsPick(let track), .yourPick(let track): track
        case .notThere: nil
        }
    }

    var isPicked: Bool {
        if case .yourPick = current { true } else { false }
    }
}

enum PickCopy {
    static func seamTitle(_ target: PickTarget) -> String {
        "For \(target.seam.name)"
    }

    static func seamDetail(_ target: PickTarget) -> String {
        "Goes into \(target.seam.side(target.target).name) on \(target.target.rawValue)"
    }

    static func status(_ target: PickTarget) -> String {
        switch target.current {
        case .antiphonsPick(let track): "Antiphon's pick: \(versionName(track))"
        case .yourPick(let track): "Your pick: \(versionName(track))"
        case .notThere: "Not in \(target.seam.side(target.target).name) yet"
        }
    }

    /// "Word Up!: The Remixes - EP · 2004 · single · 2:52"
    static func versionDetail(_ track: CatalogTrack) -> String {
        let kind = track.albumKind.map { kind in
            switch kind {
            case .album: "album"
            case .single: "single"
            case .compilation: "compilation"
            }
        }
        return [track.album, track.releaseYear.map(String.init), kind, track.durationMs.map(MatchComparison.length)]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private static func versionName(_ track: CatalogTrack) -> String {
        [track.title, track.album].compactMap { $0 }.joined(separator: ", ")
    }
}

/// The versions of one song on the other side, to pick from.
@MainActor
@Observable
final class VersionPickerModel {
    let target: PickTarget
    var query: String
    private(set) var versions: [MatchCandidate] = []
    var selected: MatchCandidate?
    private(set) var isSearching = false
    private(set) var searchFailed = false

    private let search: CatalogSearchService
    private let preferences: VersionPreferences

    init(target: PickTarget, search: CatalogSearchService, preferences: VersionPreferences) {
        self.target = target
        self.search = search
        self.preferences = preferences
        self.query = "\(target.source.artist) \(target.source.title)"
    }

    /// What's there now, the matcher's candidates, then a search for the query.
    func load() async {
        var known: [MatchCandidate] = []
        if let current = target.currentTrack { known.append(score(current)) }
        known += target.candidates
        versions = Self.unique(known)
        selected = versions.first
        await runSearch()
        if selected == nil { selected = versions.first }
    }

    func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        do {
            let found = try await search.search(text, on: target.target).map(score).sorted { $0.confidence > $1.confidence }
            let fixed = Array(versions.prefix((target.currentTrack == nil ? 0 : 1) + target.candidates.count))
            versions = Self.unique(fixed + found)
            searchFailed = false
        } catch {
            searchFailed = true
        }
    }

    func isCurrent(_ version: MatchCandidate) -> Bool {
        version.track.id == target.currentTrack?.id
    }

    /// Anything but the person's own pick: keeping Antiphon's version is a choice too.
    var canUse: Bool {
        guard let selected else { return false }
        return !(target.isPicked && isCurrent(selected))
    }

    var comparison: [MatchComparison.Row] {
        MatchComparison.rows(source: target.source, candidate: selected?.track ?? target.source)
    }

    private func score(_ track: CatalogTrack) -> MatchCandidate {
        let score = ConfidenceScorer.score(source: target.source, candidate: track, preferences: preferences)
        return MatchCandidate(track: track, confidence: score.confidence, reason: score.reason)
    }

    private static func unique(_ versions: [MatchCandidate]) -> [MatchCandidate] {
        var seen = Set<String>()
        return versions.filter { seen.insert($0.track.id).inserted }
    }
}
