import SwiftUI

/// Displays album artwork from a URL with loading state and a graceful fallback.
struct TrackArtworkView: View {
    let url: String?
    var size: CGFloat = 48
    var cornerRadius: CGFloat = 8

    var body: some View {
        Group {
            if let url, let imageURL = URL(string: url) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    case .failure:
                        fallbackView
                    case .empty:
                        ProgressView()
                            .frame(width: size, height: size)
                    @unknown default:
                        fallbackView
                    }
                }
            } else {
                fallbackView
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
    }

    private var fallbackView: some View {
        ZStack {
            Color.surfaceElevated
            Image(systemName: "music.note")
                .font(.system(size: size * 0.35))
                .foregroundStyle(Color.textTertiary)
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        TrackArtworkView(url: nil)
        TrackArtworkView(url: "https://invalid-url")
        TrackArtworkView(url: nil, size: 64, cornerRadius: 12)
    }
    .padding()
    .background(Color.appBackground)
}
