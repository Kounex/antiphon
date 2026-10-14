import Foundation

/// What a pasted Spotify client ID looks like: 32 hex characters. The check
/// is forgiving about what comes with it (spaces, a newline, the "Client ID"
/// label copied along) and says what to copy when it isn't one.
enum SpotifyClientID {
    enum Check: Equatable {
        case empty
        case valid(String)
        case invalid
    }

    static let invalidMessage = "That isn't a client ID. Spotify's Client ID is 32 letters and numbers, on your app's page in the Spotify dashboard. Antiphon doesn't need the client secret."

    static func check(_ raw: String) -> Check {
        let words = raw.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map { $0.lowercased() }
        guard !words.isEmpty else { return .empty }
        // the label copied along is fine; anything else around it isn't an ID
        let id = words.filter { $0 != "client" && $0 != "id" }
        guard id.count == 1, let only = id.first, only.wholeMatch(of: /[0-9a-f]{32}/) != nil else { return .invalid }
        return .valid(only)
    }
}
