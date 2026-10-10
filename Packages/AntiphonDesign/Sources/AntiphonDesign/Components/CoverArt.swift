import SwiftUI

/// Playlist or track artwork. Without artwork, a soft diagonal blend of two
/// `art-*` fields chosen from `seed`, stable across launches.
public struct CoverArt: View {
    public let url: URL?
    public let seed: String
    public let size: CGFloat
    public let cornerRadius: CGFloat
    /// Shows the platform source dot in the bottom-trailing corner.
    public let service: MusicService?

    public init(url: URL? = nil, seed: String, size: CGFloat, cornerRadius: CGFloat? = nil, service: MusicService? = nil) {
        self.url = url
        self.seed = seed
        self.size = size
        self.cornerRadius = cornerRadius ?? (size <= 40 ? Radius.coverSmall : Radius.cover)
        self.service = service
    }

    public var body: some View {
        ZStack(alignment: .bottomTrailing) {
            artwork
                .frame(width: size, height: size)
                .clipShape(.rect(cornerRadius: cornerRadius))
            if let service {
                PlatformDot(service: service, size: max(8, size * 0.14))
                    .padding(max(3, size * 0.06))
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var artwork: some View {
        if let url {
            AsyncImage(url: url) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                CoverPlaceholder(seed: seed)
            }
        } else {
            CoverPlaceholder(seed: seed)
        }
    }
}

/// Two `art-*` fields in a soft diagonal blend.
public struct CoverPlaceholder: View {
    public let seed: String

    public init(seed: String) { self.seed = seed }

    public var body: some View {
        let (a, b) = Self.fields(for: seed)
        LinearGradient(colors: [a, b], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// The pair of fields for a seed. Always two different fields.
    public static func fields(for seed: String) -> (Color, Color) {
        let fields = Color.artFields
        let hash = StableHash.of(seed)
        let first = Int(hash % UInt64(fields.count))
        let offset = 1 + Int((hash / 7) % UInt64(fields.count - 1))
        return (fields[first], fields[(first + offset) % fields.count])
    }
}
