import SwiftUI

/// One track in a seam with its sync state as a trailing symbol.
/// Use inside a `List` row with `.listRowBackground(Color.canvasRaised)`.
public struct TrackRow: View {
    public enum State: Hashable, Sendable {
        case synced
        case syncing
        case pending
        case review(confidence: Int)
        /// Not on the other side. Not an error: the row dims.
        case missing
        /// Something broke and needs action. Doesn't dim.
        case failed
        /// Removed on one side of a two-way seam; waiting for an answer.
        case removed
    }

    public let title: String
    /// Album normally; confidence and reason for review; reason for missing or failed.
    public let detail: String
    public let artwork: CoverArt
    public let state: State
    public let isNew: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, detail: String, artwork: CoverArt, state: State, isNew: Bool = false) {
        self.title = title
        self.detail = detail
        self.artwork = artwork
        self.state = state
        self.isNew = isNew
    }

    public var body: some View {
        HStack(spacing: Space.s3) {
            if !dynamicTypeSize.isAccessibilitySize { artwork }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.s1 + 2) {
                    Text(title).font(.headline).foregroundStyle(Color.ink)
                    if isNew {
                        Text("NEW")
                            .font(.statusLabel)
                            .tracking(TypeMetrics.statusLabelTracking)
                            .foregroundStyle(Color.thread)
                    }
                }
                Text(detail).font(.subheadline).foregroundStyle(Color.inkMuted)
            }
            Spacer(minLength: Space.s2)
            symbol
        }
        .padding(.vertical, Space.s1)
        .opacity(state == .missing ? Opacity.missing : 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(title), \(detail)"))
        .accessibilityValue(Text(Self.stateDescription(state)))
    }

    @ViewBuilder
    private var symbol: some View {
        let image = Image(systemName: Self.symbolName(state))
            .font(.title3)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(Self.symbolColor(state))
            .frame(minWidth: Space.tap * 0.6)
        if state == .syncing && !reduceMotion {
            image.symbolEffect(.rotate, options: .repeat(.continuous))
        } else {
            image
        }
    }

    public static func symbolName(_ state: State) -> String {
        switch state {
        case .synced: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .pending: "circle.dotted"
        case .review, .removed: "questionmark.circle.fill"
        case .missing: "circle.slash"
        case .failed: "exclamationmark.triangle.fill"
        }
    }

    public static func symbolColor(_ state: State) -> Color {
        switch state {
        case .synced: .statusSynced
        case .syncing: .thread
        case .pending: .inkFaint
        case .review, .removed: .statusReview
        case .missing: .statusMissing
        case .failed: .statusFailed
        }
    }

    public static func stateDescription(_ state: State) -> String {
        switch state {
        case .synced: "In sync"
        case .syncing: "Syncing"
        case .pending: "Waiting to sync"
        case .review(let confidence): "Needs review, \(confidence)% match"
        case .missing: "Not available"
        case .failed: "Failed"
        case .removed: "Removed on one side, needs your call"
        }
    }
}
