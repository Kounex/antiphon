import Foundation

/// What the widgets say. Shared by the widget extension and the app (tests,
/// the debug catalog).
enum WidgetCopy {
    static let noSeams = "No seams yet. Open Antiphon to stitch two playlists."
    /// Before the app has written its first snapshot.
    static let notLoaded = "Open Antiphon once to show your seams here."

    static func checked(_ date: Date?, now: Date) -> String {
        guard let date else { return "not checked yet" }
        return "checked \(RelativeTime.text(since: date, now: now))"
    }

    static func number(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    static func tracksAndSeams(seams: Int) -> String {
        "tracks · \(count(seams, "seam"))"
    }

    static func newThisWeek(_ new: WidgetSnapshot.NewTracks) -> String {
        guard new.tracks > 0 else { return "Nothing new this week" }
        let joiner = new.playlists == 1 ? "in" : "across"
        return "\(count(new.tracks, "track")) \(joiner) \(count(new.playlists, "playlist"))"
    }

    static func count(_ n: Int, _ noun: String) -> String {
        "\(n) \(n == 1 ? noun : noun + "s")"
    }
}

/// Where tapping a widget goes, as an `antiphon://` link the app opens.
enum WidgetLink: Equatable, Sendable {
    case seam(UUID)
    case newTracks

    var url: URL {
        switch self {
        case .seam(let id): URL(string: "antiphon://seam/\(id.uuidString)")!
        case .newTracks: URL(string: "antiphon://new-tracks")!
        }
    }

    init?(url: URL) {
        guard url.scheme == "antiphon" else { return nil }
        switch url.host() {
        case "seam":
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            self = .seam(id)
        case "new-tracks":
            self = .newTracks
        default:
            return nil
        }
    }
}
