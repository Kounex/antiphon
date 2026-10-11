import Foundation

/// The App Group the app shares with its extensions. Its identifier comes
/// from Info.plist (`group.$(ANTIPHON_BUNDLE_ID)`), so the dev app has its own.
enum AppGroup {
    static var identifier: String? {
        Bundle.main.object(forInfoDictionaryKey: "AntiphonAppGroup") as? String
    }

    static var containerURL: URL? {
        identifier.flatMap { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0) }
    }
}

/// What the widgets show, written by the app after each sync (D4). Widgets
/// read only this file; the SwiftData store stays the app's.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    enum Status: Codable, Equatable, Sendable {
        /// Close matches or removal questions waiting.
        case review(Int)
        case failed
        case paused
        case inSync
    }

    struct Seam: Codable, Equatable, Sendable, Identifiable {
        let id: UUID
        let name: String
        let artworkURL: URL?
        let status: Status
        let checkedAt: Date?
    }

    struct NewTracks: Codable, Equatable, Sendable {
        let tracks: Int
        let playlists: Int
    }

    let generatedAt: Date
    /// Every seam, the ones that need the person first.
    let seams: [Seam]
    let tracksInSync: Int
    let seamCount: Int
    let lastCheckedAt: Date?
    let newThisWeek: NewTracks

    static let fileName = "widget-snapshot.json"

    func write(to folder: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: folder.appending(path: Self.fileName), options: .atomic)
    }

    static func read(from folder: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
