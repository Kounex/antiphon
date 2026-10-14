import SwiftUI

/// How a seam's tracks stand: the health bar's three segments.
public struct SeamHealth: Hashable, Sendable {
    public var synced: Int
    public var review: Int
    public var missing: Int
    public var total: Int

    public init(synced: Int, review: Int, missing: Int, total: Int) {
        self.synced = synced
        self.review = review
        self.missing = missing
        self.total = total
    }

    /// Fractions of the bar for synced, review and missing.
    public var fractions: (synced: Double, review: Double, missing: Double) {
        guard total > 0 else { return (0, 0, 0) }
        let t = Double(total)
        return (Double(synced) / t, Double(review) / t, Double(missing) / t)
    }

    /// "48 synced, 3 to review, 1 missing"
    public var accessibilityValue: String {
        "\(synced) synced, \(review) to review, \(missing) missing"
    }
}

/// A seam at a glance on the Syncs tab. Opaque `canvas-raised`, never glass.
public struct SyncCard: View {
    public struct Status: Hashable, Sendable {
        public var isMonitoring: Bool
        public var isSyncing: Bool
        /// Its playlists are being read (the app just opened).
        public var isChecking: Bool
        public var isPaused: Bool
        /// "Failed" or "Sign in" when something broke.
        public var failure: String?

        public init(isMonitoring: Bool, isSyncing: Bool = false, isChecking: Bool = false, isPaused: Bool = false,
                    failure: String? = nil) {
            self.isMonitoring = isMonitoring
            self.isSyncing = isSyncing
            self.isChecking = isChecking
            self.isPaused = isPaused
            self.failure = failure
        }
    }

    public let title: String
    public let subtitle: String
    public let leading: CoverArt
    public let trailing: CoverArt
    public let direction: SeamDirection
    public let health: SeamHealth
    public let status: Status

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    public init(
        title: String, subtitle: String, leading: CoverArt, trailing: CoverArt,
        direction: SeamDirection, health: SeamHealth, status: Status
    ) {
        self.title = title
        self.subtitle = subtitle
        self.leading = leading
        self.trailing = trailing
        self.direction = direction
        self.health = health
        self.status = status
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            SeamLine(
                leading: leading, trailing: trailing, direction: direction,
                isMonitoring: status.isMonitoring && !status.isPaused,
                knot: Self.knot(status: status),
                style: .card
            )
            VStack(alignment: .leading, spacing: Space.s1) {
                Text(title).font(.headline).foregroundStyle(Color.ink)
                Text(subtitle).font(.footnote).foregroundStyle(Color.inkMuted)
            }
            HealthBar(health: health)
            footer
        }
        .padding(Space.s4)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
        .overlay { CardBorder(tone: Self.tone(health: health, status: status)) }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        let states = Self.pills(health: health, status: status)
        let pills = Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Space.s1 + 2) {
                    ForEach(states, id: \.self) { StatusPill($0) }
                }
            } else {
                HStack(spacing: Space.s1 + 2) {
                    ForEach(states, id: \.self) { StatusPill($0) }
                }
            }
        }
        let count = Text("\(health.synced) / \(health.total)")
            .font(.metricSmall)
            .foregroundStyle(Color.ink)
            .accessibilityLabel("\(health.synced) of \(health.total) in sync")
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Space.s2) { count; pills }
        } else {
            HStack { count; Spacer(minLength: Space.s2); pills }
        }
    }

    /// What the card's border marks. All good (and paused) has no border.
    public enum Tone: Hashable, Sendable {
        case syncing, checking, failed, review

        /// Something is happening now: the border's light runs round it.
        public var isActive: Bool { self == .syncing || self == .checking }

        var color: Color {
            switch self {
            case .syncing, .checking: .thread
            case .failed: .statusFailed
            case .review: .statusReview
            }
        }
    }

    /// Activity first (it's what changes while you look), then a failure,
    /// then tracks to review.
    public static func tone(health: SeamHealth, status: Status) -> Tone? {
        if status.isSyncing { return .syncing }
        if status.isChecking { return .checking }
        if status.failure != nil { return .failed }
        if health.review > 0 { return .review }
        return nil
    }

    /// The knot shows what the seam is doing right now: syncing, checking,
    /// a problem, paused, or its direction.
    public static func knot(status: Status) -> SeamLine.Knot {
        if status.isSyncing { return .syncing }
        if status.isChecking { return .checking }
        if status.failure != nil { return .problem }
        return status.isPaused ? .paused : .direction
    }

    /// At most two pills, by priority: Failed > Review > Syncing > Paused,
    /// Checking or Monitoring > In sync.
    public static func pills(health: SeamHealth, status: Status) -> [StatusPill.State] {
        var candidates: [StatusPill.State] = []
        if let failure = status.failure { candidates.append(.failed(failure)) }
        if health.review > 0 { candidates.append(.review(health.review)) }
        if status.isSyncing { candidates.append(.syncing) }
        if status.isPaused {
            candidates.append(.paused)
        } else if status.isChecking {
            candidates.append(.checking)
        } else if status.isMonitoring {
            candidates.append(.monitoring)
        }
        let inSync = health.total > 0 && health.synced == health.total
        if inSync && status.failure == nil { candidates.append(.inSync) }
        return Array(candidates.prefix(2))
    }
}

/// The card's border for a special state. Syncing and checking: a faint
/// gold edge with a light running round it (one lap every 2.4 s). Failed
/// and review: their color, breathing slowly. Changing state cross-fades;
/// Reduce Motion keeps a still border.
struct CardBorder: View {
    let tone: SyncCard.Tone?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let lap: TimeInterval = 2.4

    var body: some View {
        ZStack {
            if let tone {
                border(tone)
                    .id(tone)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.45), value: tone)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func border(_ tone: SyncCard.Tone) -> some View {
        let shape = RoundedRectangle(cornerRadius: Radius.card)
        let color = tone.color
        if reduceMotion {
            shape.strokeBorder(color.opacity(0.8), lineWidth: 1.5)
        } else if tone.isActive {
            TimelineView(.animation) { context in
                let lap = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.lap) / Self.lap
                shape
                    .strokeBorder(color.opacity(0.3), lineWidth: 1.5)
                    .overlay {
                        shape.strokeBorder(
                            AngularGradient(stops: [
                                .init(color: color.opacity(0), location: 0),
                                .init(color: color.opacity(0), location: 0.62),
                                .init(color: color, location: 0.9),
                                .init(color: color.opacity(0), location: 1)
                            ], center: .center, angle: .degrees(lap * 360)),
                            lineWidth: 2
                        )
                    }
            }
        } else {
            shape
                .strokeBorder(color, lineWidth: 1.5)
                .phaseAnimator([0.45, 0.95]) { border, opacity in
                    border.opacity(opacity)
                } animation: { _ in .easeInOut(duration: 1.6) }
        }
    }
}

/// Three-part health bar: synced, review, missing.
public struct HealthBar: View {
    public let health: SeamHealth
    public var height: CGFloat = 4

    public init(health: SeamHealth, height: CGFloat = 4) {
        self.health = health
        self.height = height
    }

    public var body: some View {
        let f = health.fractions
        GeometryReader { proxy in
            HStack(spacing: 1) {
                segment(.statusSynced, f.synced, proxy.size.width)
                segment(.statusReview, f.review, proxy.size.width)
                segment(.inkFaint, f.missing, proxy.size.width)
                Spacer(minLength: 0)
            }
        }
        .frame(height: height)
        .background(Color.canvasSunken, in: .capsule)
        .clipShape(.capsule)
        .accessibilityElement()
        .accessibilityLabel("Tracks")
        .accessibilityValue(health.accessibilityValue)
    }

    @ViewBuilder
    private func segment(_ color: Color, _ fraction: Double, _ width: CGFloat) -> some View {
        if fraction > 0 {
            color.frame(width: max(2, width * fraction))
        }
    }
}
