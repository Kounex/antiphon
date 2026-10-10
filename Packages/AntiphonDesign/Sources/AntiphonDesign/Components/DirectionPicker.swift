import SwiftUI

/// A glass segmented control for a seam decision, with a one-line
/// consequence directly under it that rewrites itself with the choice.
///
/// Used for direction (One way / Both ways) and removal policy (Keep it /
/// Remove it too). The arrow morphs in the seam's knot (`SeamLine`); a
/// segmented `Picker` can't animate symbols inside its segments.
public struct DirectionPicker<Value: Hashable>: View {
    public struct Option {
        public let value: Value
        public let title: String
        public let symbol: String?

        public init(_ value: Value, title: String, symbol: String? = nil) {
            self.value = value
            self.title = title
            self.symbol = symbol
        }
    }

    public let title: String
    public let options: [Option]
    @Binding public var selection: Value
    public let consequence: String

    public init(_ title: String, options: [Option], selection: Binding<Value>, consequence: String) {
        self.title = title
        self.options = options
        self._selection = selection
        self.consequence = consequence
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            GlassEffectContainer(spacing: Space.s2) {
                Picker(title, selection: $selection) {
                    ForEach(options, id: \.value) { option in
                        if let symbol = option.symbol {
                            Label(option.title, systemImage: symbol).tag(option.value)
                        } else {
                            Text(option.title).tag(option.value)
                        }
                    }
                }
                .pickerStyle(.segmented)
                .tint(.thread)
            }
            Text(consequence)
                .font(.footnote)
                .foregroundStyle(Color.inkMuted)
                .contentTransition(.opacity)
                .animation(.smooth, value: consequence)
                .padding(.horizontal, Space.s1)
                .accessibilityLabel(consequence)
        }
    }
}

public extension DirectionPicker where Value == SeamDirection {
    /// One way / Both ways.
    init(selection: Binding<SeamDirection>, consequence: String) {
        self.init(
            "Direction",
            options: [
                Option(.oneWay, title: SeamDirection.oneWay.label, symbol: SeamDirection.oneWay.symbol),
                Option(.twoWay, title: SeamDirection.twoWay.label, symbol: SeamDirection.twoWay.symbol)
            ],
            selection: selection,
            consequence: consequence
        )
    }
}
