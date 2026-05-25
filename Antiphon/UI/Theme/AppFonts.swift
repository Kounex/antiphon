import SwiftUI

extension Font {
    // MARK: - Display

    /// Large title — used for main headers
    static let appLargeTitle = Font.system(size: 34, weight: .bold, design: .rounded)

    /// Title — section headers
    static let appTitle = Font.system(size: 22, weight: .bold, design: .rounded)

    /// Title 2 — subsection headers
    static let appTitle2 = Font.system(size: 20, weight: .semibold, design: .rounded)

    /// Title 3 — card headers
    static let appTitle3 = Font.system(size: 17, weight: .semibold, design: .rounded)

    // MARK: - Body

    /// Body text
    static let appBody = Font.system(size: 16, weight: .regular)

    /// Body text — emphasized
    static let appBodyBold = Font.system(size: 16, weight: .semibold)

    // MARK: - Supporting

    /// Caption text — metadata, timestamps
    static let appCaption = Font.system(size: 13, weight: .regular)

    /// Caption text — labels
    static let appCaptionBold = Font.system(size: 13, weight: .semibold)

    /// Tiny label — badges
    static let appMicro = Font.system(size: 11, weight: .medium)

    // MARK: - Monospaced

    /// For ISRC codes and technical data
    static let appMono = Font.system(size: 13, weight: .regular, design: .monospaced)
}
