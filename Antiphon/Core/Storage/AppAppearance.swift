import SwiftUI

/// The app's theme: follow iOS, or always light or dark.
enum AppAppearance: String, CaseIterable, Sendable {
    case system, light, dark

    /// Read with `@AppStorage` at the app root so a change applies at once.
    static let storageKey = "appearance"

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
