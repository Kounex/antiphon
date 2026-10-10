import SwiftUI

/// The 10pt source dot that says which service something lives on.
public struct PlatformDot: View {
    public let service: MusicService
    public let size: CGFloat

    public init(service: MusicService, size: CGFloat = 10) {
        self.service = service
        self.size = size
    }

    public var body: some View {
        Circle()
            .fill(service.markColor)
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(Color.canvas.opacity(0.6), lineWidth: size > 12 ? 1.5 : 1))
            .accessibilityHidden(true)
    }
}

/// The source dot with the service's name beside it. The name is `ink`,
/// never the platform color.
public struct PlatformBadge: View {
    public let service: MusicService
    public let showsName: Bool

    public init(service: MusicService, showsName: Bool = true) {
        self.service = service
        self.showsName = showsName
    }

    public var body: some View {
        HStack(spacing: Space.s1 + 2) {
            PlatformDot(service: service)
            if showsName {
                Text(service.name).foregroundStyle(Color.ink)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(service.name)
    }
}

/// Full-width sign-in capsule for onboarding and the Problems screen.
///
/// OFFICIAL BADGE PLACEHOLDER: the circle on the leading edge stands in for
/// the official Spotify / Apple Music logo asset. Antiphon ships no platform
/// logos; drop the licensed badge into `BrandBadgeSlot` under each brand's
/// guidelines before release.
public struct SignInCapsule: View {
    public let service: MusicService
    public let title: String
    public let action: () -> Void

    public init(service: MusicService, title: String, action: @escaping () -> Void) {
        self.service = service
        self.title = title
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                BrandBadgeSlot(service: service)
                Text(title).font(.headline)
            }
            .frame(maxWidth: .infinity, minHeight: Space.tap + 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .tint(service.markColor)
        .foregroundStyle(service == .spotify ? Color.onSpotify : Color.onAppleMusic)
    }
}

/// Where the official brand badge goes. A plain circle until the licensed
/// asset is added; see `SignInCapsule`.
public struct BrandBadgeSlot: View {
    public let service: MusicService
    @ScaledMetric(relativeTo: .headline) private var size: CGFloat = 22

    public init(service: MusicService) { self.service = service }

    public var body: some View {
        // TODO(brand): replace with the official badge asset for this service.
        Circle()
            .strokeBorder(service == .spotify ? Color.onSpotify : Color.onAppleMusic, lineWidth: 2)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}
