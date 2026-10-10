import SwiftUI

/// Capsule buttons on Liquid Glass. One prominent (thread-tinted) button per
/// screen for the thing the screen is for; everything else is regular glass.
/// Over album art, use clear glass.
public enum GlassButtonRole: Sendable {
    /// `.glassProminent` tinted `thread`, label in `on-thread`.
    case primary
    /// Regular glass.
    case secondary
    /// Clear glass, for controls placed over artwork.
    case overArt
}

public extension View {
    /// Applies the Antiphon glass button style for `role`. With Increase
    /// Contrast on, custom glass gets a 1pt hairline outline.
    func glassButton(_ role: GlassButtonRole) -> some View {
        modifier(GlassButtonModifier(role: role))
    }
}

struct GlassButtonModifier: ViewModifier {
    let role: GlassButtonRole
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        switch role {
        case .primary:
            content
                .buttonStyle(.glassProminent)
                .tint(.thread)
                .foregroundStyle(Color.onThread)
                .controlSize(.large)
        case .secondary:
            content
                .buttonStyle(.glass)
                .foregroundStyle(Color.ink)
                .controlSize(.large)
        case .overArt:
            content
                .buttonStyle(.glass(.clear))
                .foregroundStyle(Color.ink)
                .overlay {
                    if contrast == .increased { Capsule().strokeBorder(Color.hairline, lineWidth: 1) }
                }
        }
    }
}
