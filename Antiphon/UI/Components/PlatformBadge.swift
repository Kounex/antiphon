import SwiftUI

/// A small circular badge displaying a platform's icon in its brand color.
struct PlatformBadge: View {
    let platform: Platform
    var size: BadgeSize = .regular

    enum BadgeSize {
        case small, regular, large

        var iconSize: CGFloat {
            switch self {
            case .small: return 12
            case .regular: return 16
            case .large: return 22
            }
        }

        var padding: CGFloat {
            switch self {
            case .small: return 6
            case .regular: return 8
            case .large: return 10
            }
        }
    }

    var body: some View {
        Image(systemName: platform.icon)
            .font(.system(size: size.iconSize, weight: .semibold))
            .foregroundStyle(platform.color)
            .padding(size.padding)
            .background(
                Circle()
                    .fill(platform.color.opacity(0.15))
            )
    }
}

#Preview {
    HStack(spacing: 20) {
        PlatformBadge(platform: .spotify, size: .small)
        PlatformBadge(platform: .spotify)
        PlatformBadge(platform: .spotify, size: .large)
        PlatformBadge(platform: .appleMusic, size: .small)
        PlatformBadge(platform: .appleMusic)
        PlatformBadge(platform: .appleMusic, size: .large)
    }
    .padding()
    .background(Color.appBackground)
}
