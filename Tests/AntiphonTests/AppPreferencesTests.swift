import Foundation
import Testing
@testable import Antiphon

@Suite("Preferences")
struct AppPreferencesTests {

    private func defaults() -> UserDefaults {
        let name = "test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Fresh install: 90% threshold, add-only, watching every 15 min")
    func freshDefaults() {
        let prefs = AppPreferences(defaults: defaults())
        #expect(prefs.autoAddThreshold == 90)
        #expect(prefs.newSeamRemovalPolicy == .keep)
        #expect(prefs.newSeamMonitoring)
        #expect(prefs.monitorIntervalMinutes == 15)
        #expect(prefs.hasCompletedOnboarding == false)
    }

    @Test("The interval chosen in the old Settings screen carries over")
    func legacyInterval() {
        let d = defaults()
        d.set(60, forKey: "syncIntervalMinutes")
        #expect(AppPreferences(defaults: d).monitorIntervalMinutes == 60)
    }

    @Test("Until the review queue ships, every match from 60% up is added, as before")
    func reviewQueueOff() {
        let prefs = AppPreferences(defaults: defaults())
        prefs.reviewQueueEnabled = false
        #expect(prefs.confidencePolicy.band(for: 60) == .automatic)
        #expect(prefs.confidencePolicy.band(for: 59) == .alternative)
    }

    @Test("With the review queue on, the chosen threshold applies")
    func reviewQueueOn() {
        let prefs = AppPreferences(defaults: defaults())
        prefs.reviewQueueEnabled = true
        prefs.autoAddThreshold = 80
        #expect(prefs.confidencePolicy.band(for: 80) == .automatic)
        #expect(prefs.confidencePolicy.band(for: 79) == .review)
    }

    @Test("Values persist across instances")
    func persists() {
        let d = defaults()
        let first = AppPreferences(defaults: d)
        first.autoAddThreshold = 75
        first.newSeamRemovalPolicy = .mirror
        let second = AppPreferences(defaults: d)
        #expect(second.autoAddThreshold == 75)
        #expect(second.newSeamRemovalPolicy == .mirror)
    }
}
