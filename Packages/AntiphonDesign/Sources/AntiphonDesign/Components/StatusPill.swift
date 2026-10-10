import SwiftUI

/// A compact capsule naming one state with a symbol and a word.
/// Status by shape first, color second.
public struct StatusPill: View {
    public enum State: Hashable, Sendable {
        case inSync
        case syncing
        case monitoring
        case review(Int)
        /// "Failed" or "Sign in".
        case failed(String)
        case missing(MusicService)
        case paused
    }

    public let state: State
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    public init(_ state: State) { self.state = state }

    public var body: some View {
        HStack(spacing: Space.s1) {
            symbol
            Text(label.uppercased())
                .font(.statusLabel)
                .tracking(TypeMetrics.statusLabelTracking)
                .lineLimit(1)
        }
        .foregroundStyle(foreground)
        .padding(.horizontal, Space.s2)
        .padding(.vertical, Space.s1)
        .background(background, in: .capsule)
        .overlay {
            if isDashed {
                Capsule().strokeBorder(Color.statusMissing, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            } else if contrast == .increased {
                Capsule().strokeBorder(foreground.opacity(0.6), lineWidth: 1)
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Content

    public var label: String {
        switch state {
        case .inSync: "In sync"
        case .syncing: "Syncing"
        case .monitoring: "Watching"
        case .review(let n): "Review \(n)"
        case .failed(let text): text
        case .missing(let service): "Not on \(service.name)"
        case .paused: "Paused"
        }
    }

    private var accessibilityText: String {
        switch state {
        case .review(let n): "\(n) to review"
        default: label
        }
    }

    private var symbolName: String {
        switch state {
        case .inSync: "checkmark.circle.fill"
        case .syncing: "arrow.triangle.2.circlepath"
        case .monitoring: "eye"
        case .review: "questionmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .missing: "circle.slash"
        case .paused: "pause.circle"
        }
    }

    @ViewBuilder
    private var symbol: some View {
        let image = Image(systemName: symbolName)
            .font(.caption2.weight(.semibold))
            .symbolRenderingMode(.hierarchical)
        if state == .syncing && !reduceMotion {
            image.symbolEffect(.rotate, options: .repeat(.continuous))
        } else {
            image
        }
    }

    private var foreground: Color {
        switch state {
        case .inSync: .statusSynced
        case .syncing, .monitoring: .thread
        case .review: .statusReview
        case .failed: .statusFailed
        case .missing, .paused: .statusMissing
        }
    }

    private var background: Color {
        switch state {
        case .inSync: .statusSyncedSoft
        case .syncing, .monitoring: .threadSoft
        case .review: .statusReviewSoft
        case .failed: .statusFailedSoft
        case .missing, .paused: .clear
        }
    }

    private var isDashed: Bool {
        switch state {
        case .missing, .paused: true
        default: false
        }
    }
}
