import SwiftUI

/// The tab bar is the system `TabView`: Syncs, Library, Activity, and Search
/// as its own glass circle. These are the shared pieces so every root uses
/// the same symbols, labels and badge rule.
public enum AntiphonTab: Hashable, Sendable, CaseIterable {
    case syncs, library, activity, search

    public var title: String {
        switch self {
        case .syncs: "Syncs"
        case .library: "Library"
        case .activity: "Activity"
        case .search: "Search"
        }
    }

    public var symbol: String {
        switch self {
        case .syncs: "rectangle.split.2x1"
        case .library: "books.vertical"
        case .activity: "clock.arrow.circlepath"
        case .search: "magnifyingglass"
        }
    }

    /// Syncs is badged with the number of tracks waiting for review; never
    /// for routine syncs.
    public static func syncsBadge(reviewCount: Int) -> Int {
        max(0, reviewCount)
    }
}

public extension View {
    /// The Antiphon tab bar behavior: minimize on scroll, thread tint.
    func antiphonTabBar() -> some View {
        self
            .tabBarMinimizeBehavior(.onScrollDown)
            .tint(.thread)
    }
}
