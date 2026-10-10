import SwiftUI

/// Filter chips with counts ("All 9", "Watching 7"). One is selected.
/// Scrolls horizontally when the chips don't fit.
public struct ChipBar<Value: Hashable>: View {
    public struct Chip: Identifiable {
        public let value: Value
        public let title: String
        public let count: Int?
        public var id: Value { value }

        public init(_ value: Value, _ title: String, count: Int? = nil) {
            self.value = value
            self.title = title
            self.count = count
        }
    }

    public let chips: [Chip]
    @Binding public var selection: Value

    public init(_ chips: [Chip], selection: Binding<Value>) {
        self.chips = chips
        self._selection = selection
    }

    public var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: Space.s2) {
                ForEach(chips) { chip in
                    let isOn = chip.value == selection
                    Button {
                        withAnimation(.smooth) { selection = chip.value }
                    } label: {
                        HStack(spacing: Space.s1 + 2) {
                            Text(chip.title)
                            if let count = chip.count {
                                Text("\(count)").monospacedDigit().fontWeight(.semibold)
                            }
                        }
                        .font(.subheadline)
                        .foregroundStyle(isOn ? Color.thread : Color.ink)
                        .padding(.horizontal, Space.s3)
                        .frame(minHeight: 36)
                        .background(isOn ? Color.threadSoft : Color.canvasRaised, in: .capsule)
                        .contentShape(.capsule)
                    }
                    .buttonStyle(.plain)
                    .frame(minHeight: Space.tap)
                    .accessibilityAddTraits(isOn ? .isSelected : [])
                    .accessibilityLabel(chip.count.map { "\(chip.title), \($0)" } ?? chip.title)
                }
            }
        }
        .scrollIndicators(.hidden)
    }
}
