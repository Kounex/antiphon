import SwiftUI
import UIKit

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

    /// The Home Screen icon. System keeps the primary icon, which already
    /// follows iOS's light, dark and tinted modes.
    var alternateIconName: String? {
        switch self {
        case .system: nil
        case .light: "AppIcon-Light"
        case .dark: "AppIcon-Dark"
        }
    }

    var interfaceStyle: UIUserInterfaceStyle {
        switch self {
        case .system: .unspecified
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

/// Applies the theme to the app's windows. Set on the window, it reaches
/// sheets that are already open; `preferredColorScheme` doesn't.
@MainActor
enum AppearanceApplier {
    static func apply(_ appearance: AppAppearance) {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows { window.overrideUserInterfaceStyle = appearance.interfaceStyle }
        }
    }
}

/// Switches the Home Screen icon to match the theme. iOS confirms every
/// change with its own short notice; apps can't avoid it.
@MainActor
enum AppIconSwitcher {
    static func apply(_ appearance: AppAppearance) async {
        let application = UIApplication.shared
        guard application.supportsAlternateIcons else { return }
        // iOS cancels icon changes while the app isn't active yet (seen at
        // launch): wait for it, and try once more if it still refuses.
        for attempt in 1...2 {
            for _ in 0..<20 where application.applicationState != .active {
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard application.alternateIconName != appearance.alternateIconName else { return }
            do {
                try await application.setAlternateIconName(appearance.alternateIconName)
                return
            } catch {
                print("[AppIconSwitcher] Couldn't change the icon (try \(attempt)): \(error.localizedDescription)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
