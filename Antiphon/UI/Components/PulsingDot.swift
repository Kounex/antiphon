import SwiftUI

/// An animated pulsing dot to indicate active monitoring or live status.
struct PulsingDot: View {
    let color: Color
    var size: CGFloat = 10

    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // Pulse ring
            Circle()
                .fill(color.opacity(0.3))
                .frame(width: size * 2.5, height: size * 2.5)
                .scaleEffect(reduceMotion ? 0.75 : (isPulsing ? 1.0 : 0.5))
                .opacity(reduceMotion ? 0.6 : (isPulsing ? 0 : 0.6))

            // Core dot
            Circle()
                .fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.5), radius: 4)
        }
        .task(id: reduceMotion) {
            guard !reduceMotion else { return }
            withAnimation(
                .easeInOut(duration: 1.5)
                    .repeatForever(autoreverses: false)
            ) {
                isPulsing = true
            }
        }
    }
}

#Preview {
    HStack(spacing: 40) {
        PulsingDot(color: .syncSuccess)
        PulsingDot(color: .spotifyGreen)
        PulsingDot(color: .appleMusicPink)
    }
    .padding(40)
    .background(Color.appBackground)
}
