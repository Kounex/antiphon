import SwiftUI

/// A settings row: title, a one-line consequence, and a thread-tinted switch.
/// The description states what will happen, including the real interval.
public struct MonitorToggle: View {
    public let title: String
    public let description: String
    @Binding public var isOn: Bool

    public init(_ title: String, description: String, isOn: Binding<Bool>) {
        self.title = title
        self.description = description
        self._isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(Color.ink)
                Text(description).font(.footnote).foregroundStyle(Color.inkMuted)
            }
        }
        .tint(.thread)
        .frame(minHeight: Space.tap)
    }
}

/// A transient glass capsule confirming an action in past tense
/// ("Paused. Antiphon won't change Late Night Drive until you turn this back on.").
public struct GlassToast: View {
    public let message: String
    public let symbol: String?
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ message: String, symbol: String? = nil) {
        self.message = message
        self.symbol = symbol
    }

    public var body: some View {
        HStack(spacing: Space.s2) {
            if let symbol {
                Image(systemName: symbol).foregroundStyle(Color.thread)
            }
            Text(message).font(.callout).foregroundStyle(Color.ink)
        }
        .padding(.horizontal, Space.s5)
        .padding(.vertical, Space.s3)
        .glassEffect(.regular, in: .capsule)
        .overlay { if contrast == .increased { Capsule().strokeBorder(Color.hairline, lineWidth: 1) } }
        .padding(.horizontal, Space.s4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isStaticText)
    }
}
