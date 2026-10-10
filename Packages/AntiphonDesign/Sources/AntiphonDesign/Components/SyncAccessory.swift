import SwiftUI

/// While a sync runs, a glass capsule above the tab bar like Music's mini
/// player: the playlist, progress in tracks, and a ring. Place it in
/// `.tabViewBottomAccessory`; it drops its second line when the tab bar
/// minimizes and the accessory goes inline.
public struct SyncAccessory: View {
    /// "Syncing Run Club" or "Syncing 3 playlists".
    public let title: String
    /// "31 of 52 · Spotify → Apple Music"
    public let detail: String
    public let done: Int
    public let total: Int
    public let artwork: CoverArt

    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    public init(title: String, detail: String, done: Int, total: Int, artwork: CoverArt) {
        self.title = title
        self.detail = detail
        self.done = done
        self.total = total
        self.artwork = artwork
    }

    public var fraction: Double { total > 0 ? Double(done) / Double(total) : 0 }

    public var body: some View {
        HStack(spacing: Space.s3) {
            artwork
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1)
                if placement != .inline {
                    Text(detail).font(.caption.monospacedDigit()).foregroundStyle(Color.inkMuted).lineLimit(1)
                }
            }
            Spacer(minLength: Space.s2)
            ProgressRing(fraction: fraction)
        }
        .padding(.horizontal, Space.s3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue("\(done) of \(total) tracks")
        .accessibilityHint("Opens the live sync")
    }
}

/// The accessory's progress ring.
public struct ProgressRing: View {
    public let fraction: Double
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 26

    public init(fraction: Double) { self.fraction = fraction }

    public var body: some View {
        ZStack {
            Circle().stroke(Color.hairline, lineWidth: 3)
            Circle()
                .trim(from: 0, to: min(1, max(0, fraction)))
                .stroke(Color.thread, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.smooth, value: fraction)
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent done")
    }
}
