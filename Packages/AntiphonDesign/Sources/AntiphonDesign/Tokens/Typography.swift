import SwiftUI

/// Type tokens. All map to Dynamic Type styles, so every screen scales to AX5.
public extension Font {
    /// Tab roots: Syncs, Library, Activity.
    static let antiphonLargeTitle = Font.largeTitle.bold()
    /// A playlist's name on its detail screen.
    static let antiphonTitle1 = Font.title.bold()
    /// Sheet and step headings.
    static let antiphonTitle2 = Font.title2.bold()
    /// Section heads inside a screen.
    static let antiphonTitle3 = Font.title3.weight(.semibold)
    /// Status pill labels (use uppercase with `statusLabelTracking`).
    static let statusLabel = Font.caption.weight(.medium)
    /// ISRCs, playlist and snapshot IDs.
    static let code = Font.footnote.monospaced().weight(.medium)
    /// Counts inside cards and the sync accessory ("48 / 52").
    static let metricSmall = Font.system(.subheadline, design: .rounded, weight: .semibold).monospacedDigit()
    /// Stat tiles and day totals ("+12").
    static let metric = Font.system(.title, design: .rounded, weight: .semibold).monospacedDigit()
}

public enum TypeMetrics {
    /// +0.6pt tracking for uppercase status pill labels.
    public static let statusLabelTracking: CGFloat = 0.6
}

/// The one hero number per screen ("1,284"): 56pt rounded bold with
/// monospaced digits, scaled with Dynamic Type relative to Large Title.
public struct MetricXLModifier: ViewModifier {
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 56

    public func body(content: Content) -> some View {
        content.font(.system(size: size, weight: .bold, design: .rounded).monospacedDigit())
    }
}

public extension View {
    func metricXL() -> some View { modifier(MetricXLModifier()) }
}
