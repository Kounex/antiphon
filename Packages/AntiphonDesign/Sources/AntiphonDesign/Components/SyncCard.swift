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
        public var isPaused: Bool
        /// "Failed" or "Sign in" when something broke.
        public var failure: String?

        public init(isMonitoring: Bool, isSyncing: Bool = false, isPaused: Bool = false, failure: String? = nil) {
            self.isMonitoring = isMonitoring
            self.isSyncing = isSyncing
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
                knot: status.failure != nil ? .problem : (status.isPaused ? .paused : .direction),
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
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        let pills = HStack(spacing: Space.s1 + 2) {
            ForEach(Self.pills(health: health, status: status), id: \.self) { StatusPill($0) }
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

    /// At most two pills, by priority: Failed > Review > Syncing > Monitoring > In sync.
    public static func pills(health: SeamHealth, status: Status) -> [StatusPill.State] {
        var candidates: [StatusPill.State] = []
        if let failure = status.failure { candidates.append(.failed(failure)) }
        if health.review > 0 { candidates.append(.review(health.review)) }
        if status.isSyncing { candidates.append(.syncing) }
        if status.isPaused {
            candidates.append(.paused)
        } else if status.isMonitoring {
            candidates.append(.monitoring)
        }
        let inSync = health.total > 0 && health.synced == health.total
        if inSync && status.failure == nil { candidates.append(.inSync) }
        return Array(candidates.prefix(2))
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
