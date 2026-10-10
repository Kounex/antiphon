import SwiftUI

/// An inline notice with a symbol, a headline, one line of detail and an
/// optional action ("5 tracks need your call", "Not on Apple Music in Germany").
public struct Banner<Action: View>: View {
    public enum Tone: Sendable { case review, failed, neutral, thread }

    public let tone: Tone
    public let symbol: String
    public let title: String
    public let message: String
    @ViewBuilder public let action: () -> Action

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(tone: Tone, symbol: String, title: String, message: String, @ViewBuilder action: @escaping () -> Action) {
        self.tone = tone
        self.symbol = symbol
        self.title = title
        self.message = message
        self.action = action
    }

    public var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s3))
            : AnyLayout(HStackLayout(alignment: .center, spacing: Space.s3))
        layout {
            HStack(alignment: .firstTextBaseline, spacing: Space.s3) {
                Image(systemName: symbol)
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(symbolColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Space.s1) {
                    Text(title).font(.headline).foregroundStyle(Color.ink)
                    Text(message).font(.footnote).foregroundStyle(Color.inkMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(Space.s4)
        .background(background, in: .rect(cornerRadius: Radius.row))
        .accessibilityElement(children: .combine)
    }

    private var symbolColor: Color {
        switch tone {
        case .review: .statusReview
        case .failed: .statusFailed
        case .neutral: .statusMissing
        case .thread: .thread
        }
    }

    private var background: Color {
        switch tone {
        case .review: .statusReviewSoft
        case .failed: .statusFailedSoft
        case .neutral: .canvasRaised
        case .thread: .threadSoft
        }
    }
}

public extension Banner where Action == EmptyView {
    init(tone: Tone, symbol: String, title: String, message: String) {
        self.init(tone: tone, symbol: symbol, title: title, message: message) { EmptyView() }
    }
}
