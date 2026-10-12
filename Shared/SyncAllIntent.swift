import AppIntents

/// The widget's Sync all button. A `LiveActivityIntent` runs in the app's
/// process (D4), so it uses the app's store and can start the Live Activity.
/// The type exists in the widget too, for `Button(intent:)`; only the app
/// target (`ANTIPHON_APP`) does the work.
struct SyncAllIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Sync all"
    static let description = IntentDescription("Syncs every seam now, the way a background check does: close matches wait in Review.")
    static let isDiscoverable = false

    func perform() async throws -> some IntentResult {
        #if ANTIPHON_APP
        await SyncAllRunner.run()
        #endif
        return .result()
    }
}
