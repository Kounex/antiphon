import SwiftUI

extension Font {
    // MARK: - Display

    /// Large title — used for main headers
    static let appLargeTitle = Font.system(.largeTitle, design: .rounded)

    /// Title — section headers
    static let appTitle = Font.system(.title2, design: .rounded).weight(.bold)

    /// Title 2 — subsection headers
    static let appTitle2 = Font.system(.title3, design: .rounded).weight(.semibold)

    /// Title 3 — card headers
    static let appTitle3 = Font.system(.headline, design: .rounded)

    // MARK: - Body

    /// Body text
    static let appBody = Font.body

    /// Body text — emphasized
    static let appBodyBold = Font.body.weight(.semibold)

    // MARK: - Supporting

    /// Caption text — metadata, timestamps
    static let appCaption = Font.footnote

    /// Caption text — labels
    static let appCaptionBold = Font.footnote.weight(.semibold)

    /// Tiny label — badges
    static let appMicro = Font.caption2.weight(.medium)

    // MARK: - Monospaced

    /// For ISRC codes and technical data
    static let appMono = Font.footnote.monospaced()
}
