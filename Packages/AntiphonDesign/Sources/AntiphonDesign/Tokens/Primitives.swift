import SwiftUI

/// The two services Antiphon connects. Kept separate from the app's model
/// types so widgets and extensions can use the components too.
public enum MusicService: String, Hashable, Sendable, CaseIterable {
    case spotify
    case appleMusic

    public var name: String {
        switch self {
        case .spotify: "Spotify"
        case .appleMusic: "Apple Music"
        }
    }

    /// The source dot's color. Never used for text or states.
    public var markColor: Color {
        switch self {
        case .spotify: .spotify
        case .appleMusic: .appleMusic
        }
    }
}

/// Which way a seam copies tracks.
public enum SeamDirection: Hashable, Sendable {
    case oneWay
    case twoWay

    public var symbol: String {
        switch self {
        case .oneWay: "arrow.right"
        case .twoWay: "arrow.left.arrow.right"
        }
    }

    public var label: String {
        switch self {
        case .oneWay: "One way"
        case .twoWay: "Both ways"
        }
    }
}

/// A deterministic hash (Swift's `hashValue` changes per launch), so a
/// playlist keeps the same placeholder cover across launches.
enum StableHash {
    static func of(_ string: String) -> UInt64 {
        string.unicodeScalars.reduce(5381) { ($0 &* 33) &+ UInt64($1.value) }
    }
}
