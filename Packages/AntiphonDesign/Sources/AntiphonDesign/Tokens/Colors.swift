import SwiftUI

/// Color tokens from `design/design-system/tokens.json`, generated into the
/// package's asset catalog by `scripts/generate_color_assets.py`.
/// Every token has light and dark values; some have Increase Contrast values.
public extension Color {
    // Ground
    static let canvas = Color("canvas", bundle: .module)
    static let canvasRaised = Color("canvas-raised", bundle: .module)
    static let canvasSunken = Color("canvas-sunken", bundle: .module)

    // Text
    static let ink = Color("ink", bundle: .module)
    static let inkMuted = Color("ink-muted", bundle: .module)
    /// Decoration only: chevrons, disabled labels. Below 4.5:1 by design.
    static let inkFaint = Color("ink-faint", bundle: .module)
    static let hairline = Color("hairline", bundle: .module)

    // Accent: the golden thread
    static let thread = Color("thread", bundle: .module)
    static let threadSoft = Color("thread-soft", bundle: .module)
    static let onThread = Color("on-thread", bundle: .module)

    // Platform marks (never text, never a state)
    static let spotify = Color("spotify", bundle: .module)
    static let onSpotify = Color("on-spotify", bundle: .module)
    static let appleMusic = Color("applemusic", bundle: .module)
    static let onAppleMusic = Color("on-applemusic", bundle: .module)

    // States
    static let statusSynced = Color("status-synced", bundle: .module)
    static let statusSyncedSoft = Color("status-synced-soft", bundle: .module)
    static let statusReview = Color("status-review", bundle: .module)
    static let statusReviewSoft = Color("status-review-soft", bundle: .module)
    static let statusFailed = Color("status-failed", bundle: .module)
    static let statusFailedSoft = Color("status-failed-soft", bundle: .module)
    static let statusMissing = Color("status-missing", bundle: .module)

    static let focusRing = Color("focus-ring", bundle: .module)

    // Placeholder cover fields
    static let artEmber = Color("art-ember", bundle: .module)
    static let artMoss = Color("art-moss", bundle: .module)
    static let artTide = Color("art-tide", bundle: .module)
    static let artDusk = Color("art-dusk", bundle: .module)
    static let artSand = Color("art-sand", bundle: .module)

    static let artFields: [Color] = [.artEmber, .artMoss, .artTide, .artDusk, .artSand]
}
