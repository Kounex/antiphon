import SwiftUI

/// The signature element: two covers joined by a stitched golden thread,
/// with a knot that shows the direction.
///
/// While monitoring, stitches drift at one stitch per second in the sync
/// direction (two-way drifts both halves toward the middle). Paused seams
/// stand still in `ink-faint` with a pause knot. With Reduce Motion the
/// stitch is static and a small dot pulses at the knot instead.
public struct SeamLine: View {
    public enum Style: Sendable {
        /// Inside cards: opaque knot.
        case card
        /// Seam detail and setup: glass knot, larger.
        case hero
        /// Rows: no knot.
        case compact
    }

    public enum Knot: Hashable, Sendable {
        case direction
        case paused
        /// A conflict or failure on this seam.
        case problem
    }

    public let leading: CoverArt
    public let trailing: CoverArt
    public let direction: SeamDirection
    public let isMonitoring: Bool
    public let knot: Knot
    public let style: Style

    public init(
        leading: CoverArt,
        trailing: CoverArt,
        direction: SeamDirection,
        isMonitoring: Bool,
        knot: Knot = .direction,
        style: Style = .card
    ) {
        self.leading = leading
        self.trailing = trailing
        self.direction = direction
        self.isMonitoring = isMonitoring
        self.knot = knot
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 0) {
            leading
            Stitch(direction: direction, isLive: isMonitoring && knot != .paused, isProblem: knot == .problem)
                .frame(minWidth: 16, maxWidth: .infinity)
                .frame(height: 28)
                .overlay {
                    if style != .compact {
                        KnotView(direction: direction, knot: effectiveKnot, isGlass: style == .hero, isLive: isMonitoring)
                    }
                }
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var effectiveKnot: Knot {
        knot == .direction && !isMonitoring ? .paused : knot
    }

    private var accessibilityLabel: String {
        var parts = [direction == .twoWay ? "Linked both ways" : "Linked one way"]
        switch effectiveKnot {
        case .direction: parts.append("watching")
        case .paused: parts.append("not watching")
        case .problem: parts.append("needs attention")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Stitch

/// The dashed thread. `phase` advances one stitch (12pt) per second.
struct Stitch: View {
    let direction: SeamDirection
    let isLive: Bool
    let isProblem: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private static let dash: [CGFloat] = [7, 5]
    private static let period: CGFloat = 12

    var body: some View {
        let animate = isLive && !reduceMotion
        TimelineView(.animation(paused: !animate)) { context in
            let phase = animate ? CGFloat(context.date.timeIntervalSinceReferenceDate).truncatingRemainder(dividingBy: 1) * Self.period : 0
            let color = color
            let dash = Self.dash
            let direction = direction
            Canvas { canvas, size in
                let y = size.height / 2
                let mid = size.width / 2
                func stroke(from x0: CGFloat, to x1: CGFloat, phase: CGFloat) {
                    var path = Path()
                    path.move(to: CGPoint(x: x0, y: y))
                    path.addLine(to: CGPoint(x: x1, y: y))
                    canvas.stroke(path, with: .color(color),
                                  style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dash, dashPhase: phase))
                }
                switch direction {
                case .oneWay:
                    // Negative phase moves dashes toward the trailing cover.
                    stroke(from: 0, to: size.width, phase: -phase)
                case .twoWay:
                    stroke(from: 0, to: mid, phase: -phase)
                    stroke(from: size.width, to: mid, phase: -phase)
                }
            }
        }
        .accessibilityHidden(true)
    }

    private var color: Color {
        if isProblem { return .statusFailed }
        return isLive ? .thread : .inkFaint
    }
}

// MARK: - Knot

struct KnotView: View {
    let direction: SeamDirection
    let knot: SeamLine.Knot
    let isGlass: Bool
    let isLive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 28

    var body: some View {
        ZStack {
            if isGlass {
                Color.clear
                    .frame(width: size, height: size)
                    .glassEffect(.regular, in: .circle)
                    .overlay { if contrast == .increased { Circle().strokeBorder(Color.hairline, lineWidth: 1) } }
            } else {
                Circle()
                    .fill(Color.canvasRaised)
                    .overlay(Circle().strokeBorder(Color.hairline, lineWidth: 1))
                    .frame(width: size, height: size)
            }
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace))
                .animation(.smooth, value: symbol)
            if reduceMotion && isLive && knot == .direction {
                PulseDot()
                    .offset(y: size * 0.62)
            }
        }
    }

    private var symbol: String {
        switch knot {
        case .direction: direction.symbol
        case .paused: "pause.fill"
        case .problem: "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch knot {
        case .direction: .thread
        case .paused: .inkMuted
        case .problem: .statusFailed
        }
    }
}

/// Reduce Motion stand-in for the drifting stitch: a 4pt thread dot that
/// pulses once every 2 s.
struct PulseDot: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { context in
            Circle()
                .fill(Color.thread)
                .frame(width: 4, height: 4)
                .phaseAnimator([false, true], trigger: context.date) { dot, on in
                    dot.opacity(on ? 1 : 0.3)
                } animation: { _ in .easeInOut(duration: 0.5) }
        }
        .accessibilityHidden(true)
    }
}
