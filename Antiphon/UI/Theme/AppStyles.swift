import SwiftUI

// MARK: - Glass Card Modifier

/// Applies a frosted-glass card appearance with rounded corners and a subtle border.
struct GlassCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 16
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .fill(AppGradients.glass)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(Color.subtleBorder, lineWidth: 1)
                    )
            )
    }
}

extension View {
    /// Wraps the view in a glass-morphism card.
    func glassCard(cornerRadius: CGFloat = 16, padding: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

// MARK: - Primary Button Style

/// The app's primary call-to-action button style with brand gradient.
struct AntiphonButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appBodyBold)
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(AppGradients.brand)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

// MARK: - Secondary Button Style

/// A subdued button style for secondary actions.
struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.appBodyBold)
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.surfaceElevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.subtleBorder, lineWidth: 1)
                    )
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.9 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AntiphonButtonStyle {
    /// The primary Antiphon button style.
    static var antiphon: AntiphonButtonStyle { AntiphonButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    /// A secondary button style for less prominent actions.
    static var secondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

// MARK: - Shimmer Animation Modifier

/// Adds a subtle shimmer animation overlay, useful for loading placeholders.
struct ShimmerModifier: ViewModifier {
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .overlay(
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(0.1),
                        .clear,
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .rotationEffect(.degrees(30))
                .offset(x: phase)
            )
            .clipped()
            .onAppear {
                withAnimation(
                    .linear(duration: 2.0)
                        .repeatForever(autoreverses: false)
                ) {
                    phase = 400
                }
            }
    }
}

extension View {
    /// Applies a repeating shimmer animation overlay.
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}
