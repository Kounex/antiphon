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

    /// Everything the widgets show, whenever it was built.
    func hasSameContent(as other: WidgetSnapshot) -> Bool {
        seams == other.seams && tracksInSync == other.tracksInSync && seamCount == other.seamCount
            && lastCheckedAt == other.lastCheckedAt && newThisWeek == other.newThisWeek
    }

    static let fileName = "widget-snapshot.json"
    static let coversFolder = "covers"

    /// Where the app keeps a small copy of `url`'s artwork for the widgets,
    /// named by a stable hash of the URL.
    static func coverFile(for url: URL, in folder: URL) -> URL {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in url.absoluteString.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return folder.appending(path: coversFolder).appending(path: String(hash, radix: 16) + ".jpg")
    }

    /// The covers already saved for these seams, by seam.
    func covers(in folder: URL) -> [UUID: Data] {
        var covers: [UUID: Data] = [:]
        for seam in seams {
            if let url = seam.artworkURL, let data = try? Data(contentsOf: Self.coverFile(for: url, in: folder)) {
                covers[seam.id] = data
            }
        }
        return covers
    }

    /// Shown in the widget gallery and the debug catalog.
    static let sample = WidgetSnapshot(
        generatedAt: Date(),
        seams: [
            Seam(id: UUID(), name: "Late Night Drive", artworkURL: nil, status: .review(3), checkedAt: Date().addingTimeInterval(-120)),
            Seam(id: UUID(), name: "Garden Sundays", artworkURL: nil, status: .inSync, checkedAt: Date().addingTimeInterval(-300))
        ],
        tracksInSync: 1_284, seamCount: 9, lastCheckedAt: Date().addingTimeInterval(-120),
        newThisWeek: NewTracks(tracks: 14, playlists: 3)
    )

    func write(to folder: URL) throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: folder.appending(path: Self.fileName), options: .atomic)
    }

    static func read(from folder: URL) -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: folder.appending(path: fileName)) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }
}
