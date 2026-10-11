import Foundation

/// Values and consequences shown in Settings. Every row shows its current
/// value; every choice says what it does.
enum SettingsCopy {
    static func header(seams: Int, tracksInSync: Int, locale: Locale = .current) -> String {
        "\(PlanCopy.count(seams, "seam")) · \(tracksInSync.formatted(.number.locale(locale))) \(tracksInSync == 1 ? "track" : "tracks") in sync"
    }

    static func newSeamDefaults(_ policy: RemovalPolicy) -> String {
        switch policy {
        case .keep, .ask: "Add only"
        case .mirror: "Mirror exactly"
        }
    }

    static func monitoring(isOn: Bool, minutes: Int) -> String {
        isOn ? RulesCopy.intervalLabel(minutes) : "Off"
    }

    static func disconnectEffect(seams: Int) -> String {
        seams == 0
            ? "Your playlists stay exactly as they are."
            : "Syncing stops until you connect again. Your playlists stay exactly as they are on both services."
    }

    /// "Premium · signed in since 3 March 2026". The plan only shows when
    /// Spotify returns it.
    static func spotifyLine(product: String?, signedInAt: Date?, locale: Locale = .current,
                            timeZone: TimeZone = .current) -> String? {
        let since = signedInAt.map { date in
            "signed in since \(date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, timeZone: timeZone)))"
        }
        let parts = [product.flatMap { $0.isEmpty ? nil : $0.capitalized }, since].compactMap { $0 }
        guard let first = parts.first else { return nil }
        let line = ([first] + parts.dropFirst()).joined(separator: " · ")
        return line.prefix(1).uppercased() + line.dropFirst()
    }

    static func quietHours(_ hours: MonitorGates.QuietHours) -> String {
        "\(clock(hours.startMinute))–\(clock(hours.endMinute))"
    }

    static func clock(_ minute: Int) -> String {
        String(format: "%02d:%02d", minute / 60, minute % 60)
    }

    static func newTracks(_ choice: MonitorNotifications.NewTracks) -> String {
        switch choice {
        case .off: "Off"
        case .eachSync: "Each sync"
        case .dailySummary: "Daily summary"
        }
    }

    static func explicit(_ choice: ExplicitPreference) -> String {
        switch choice {
        case .sameAsSource: "Same as source"
        case .explicit: "Explicit"
        case .clean: "Clean"
        }
    }
}

enum MatchingCopy {
    /// "Last month this would have asked about 14 of 412 tracks."
    static func wouldAsk(_ confidences: [Int], threshold: Int) -> String {
        guard !confidences.isEmpty else { return "Once Antiphon has matched some tracks, this shows how often it would ask." }
        let asked = confidences.filter { $0 < threshold }.count
        return "Last month this would have asked about \(asked) of \(PlanCopy.count(confidences.count, "track"))."
    }

    static func threshold(_ value: Int) -> String {
        value >= 100 ? "Ask me unless the ISRC matches" : "Ask me below \(value)%"
    }
}
