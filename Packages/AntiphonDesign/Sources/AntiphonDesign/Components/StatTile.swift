import SwiftUI

/// A count and its label: "48 In sync". Used in a row of three.
public struct StatTile: View {
    public let value: Int
    public let label: String
    public let tint: Color

    public init(_ value: Int, _ label: String, tint: Color = .ink) {
        self.value = value
        self.label = label
        self.tint = tint
    }

    public var body: some View {
        VStack(spacing: 2) {
            Text("\(value)").font(.metric).foregroundStyle(tint)
            Text(label).font(.footnote).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s3)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.row))
        .accessibilityElement(children: .combine)
    }
}

/// Three tiles in a row; stacked at accessibility sizes.
public struct StatTiles: View {
    public let tiles: [StatTile]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(_ tiles: [StatTile]) { self.tiles = tiles }

    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Space.s2))
            : AnyLayout(HStackLayout(spacing: Space.s2))
        layout {
            ForEach(Array(tiles.enumerated()), id: \.offset) { $0.element }
        }
    }
}
