import SwiftUI

/// How sure Antiphon is that two tracks are the same recording, with the reason.
public struct ConfidenceMeter: View {
    public enum Band: Hashable, Sendable {
        case automatic, review, alternative

        public var color: Color {
            switch self {
            case .automatic: .statusSynced
            case .review: .statusReview
            case .alternative: .statusFailed
            }
        }
    }

    public let confidence: Int
    public let reason: String
    public let isrc: String?
    /// The auto-add threshold from Settings › Matching.
    public let threshold: Int

    public init(confidence: Int, reason: String, isrc: String? = nil, threshold: Int = 90) {
        self.confidence = confidence
        self.reason = reason
        self.isrc = isrc
        self.threshold = threshold
    }

    @ScaledMetric(relativeTo: .caption2) private var barWidth: CGFloat = 64

    public var body: some View {
        let band = Self.band(confidence, threshold: threshold)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Space.s3) { meter(band); reasonText }
            VStack(alignment: .leading, spacing: Space.s2) { meter(band); reasonText }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(confidence)% match")
        .accessibilityValue(isrc.map { "\(reason). ISRC \($0)" } ?? reason)
    }

    /// Grows with text a little, but never crowds out the percentage.
    private var cappedBarWidth: CGFloat { min(barWidth, 96) }

    private func meter(_ band: Band) -> some View {
        HStack(spacing: Space.s2) {
            Capsule()
                .fill(Color.canvasSunken)
                .frame(width: cappedBarWidth, height: 6)
                .overlay(alignment: .leading) {
                    Capsule().fill(band.color).frame(width: cappedBarWidth * CGFloat(min(100, max(0, confidence))) / 100)
                }
            Text("\(confidence)%").font(.metricSmall).foregroundStyle(band.color).fixedSize()
        }
    }

    private var reasonText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(reason).font(.footnote).foregroundStyle(Color.inkMuted)
            if let isrc {
                Text(isrc)
                    .font(.code)
                    .foregroundStyle(Color.ink)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.canvasSunken, in: .rect(cornerRadius: 6))
            }
        }
    }

    /// 90+ automatic (or the chosen threshold), 60 up to it review, below 60 alternative.
    public static func band(_ confidence: Int, threshold: Int = 90) -> Band {
        if confidence >= threshold { return .automatic }
        if confidence >= 60 { return .review }
        return .alternative
    }
}
