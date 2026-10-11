import Foundation

/// One-line consequences for each seam rule. Each rewrites itself when the
/// choice changes, so the effect is never a guess.
enum RulesCopy {

    static func direction(_ direction: SyncDirection) -> String {
        switch direction {
        case .spotifyToApple:
            "Tracks added on Spotify are added on Apple Music. Changes made on Apple Music stay there."
        case .appleToSpotify:
            "Tracks added on Apple Music are added on Spotify. Changes made on Spotify stay there."
        case .bidirectional:
            "Changes on either side are copied to the other. If a track is removed on one side, Antiphon asks before removing it on the other."
        }
    }

    static func removal(_ policy: RemovalPolicy, direction: SyncDirection) -> String {
        guard direction != .bidirectional else {
            switch policy {
            case .ask: return "If a track is removed on one side, Antiphon asks before touching the other."
            case .mirror: return "A track removed on either side is removed on the other too. You can undo it from Activity."
            case .keep: return "A track removed on one side stays on the other."
            }
        }
        let source = direction == .appleToSpotify ? "Apple Music" : "Spotify"
        let target = direction == .appleToSpotify ? "Spotify" : "Apple Music"
        switch policy {
        case .keep: return "Removing a track on \(source) won't touch \(target)."
        case .mirror: return "Removing a track on \(source) removes it on \(target) too. You can undo it from Activity."
        case .ask: return "If you remove a track on \(source), Antiphon asks before removing it on \(target)."
        }
    }

    static func order(_ placement: TrackPlacement, direction: SyncDirection, appleMusicCanReorder: Bool) -> String {
        guard placement == .sourceOrder else { return "New tracks go at the end of the playlist." }
        let appleLimit = "Apple only lets apps reorder playlists they created."
        switch direction {
        case .spotifyToApple:
            return appleMusicCanReorder ? "New tracks go where they are on Spotify." : "New tracks go at the end on Apple Music: \(appleLimit)"
        case .appleToSpotify:
            return "New tracks go where they are on Apple Music."
        case .bidirectional:
            let both = "New tracks go next to the same tracks as on the other side."
            return appleMusicCanReorder ? both : "\(both) On Apple Music they go at the end: \(appleLimit)"
        }
    }

    static func monitoring(isOn: Bool, interval: Int, direction: SyncDirection) -> String {
        guard isOn, interval > 0 else { return "Antiphon only syncs when you ask." }
        let what = switch direction {
        case .spotifyToApple: "Spotify"
        case .appleToSpotify: "Apple Music"
        case .bidirectional: "both playlists"
        }
        return "Checks \(what) about every \(intervalPhrase(interval)) and syncs new tracks. iOS decides the exact moment."
    }

    /// Choices for "Check every", in minutes. 0 is "Only when I ask".
    static let intervals = [15, 60, 720, 1440]

    static func intervalLabel(_ minutes: Int) -> String {
        switch minutes {
        case 0: "Only when I ask"
        case 15: "15 min"
        case 60: "Hourly"
        case 720: "Twice a day"
        case 1440: "Daily"
        default: "\(minutes) min"
        }
    }

    /// "15 min", "hour", "12 hours", "day" — as in "about every …".
    static func intervalPhrase(_ minutes: Int) -> String {
        switch minutes {
        case 60: "hour"
        case 720: "12 hours"
        case 1440: "day"
        default: "\(minutes) min"
        }
    }
}
