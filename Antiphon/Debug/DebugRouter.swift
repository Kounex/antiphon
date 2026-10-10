#if DEBUG
import SwiftUI

/// Opens a screen directly from launch arguments, for screenshots:
///     -AntiphonScreen catalog
///     -AntiphonScreen catalog/SeamLine
/// Unknown values fall back to the normal root.
enum DebugRoute {
    case catalog(ComponentCatalogView.Page?)

    static var current: DebugRoute? {
        guard let value = UserDefaults.standard.string(forKey: "AntiphonScreen") else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1).map(String.init)
        switch parts.first {
        case "catalog":
            return .catalog(parts.count > 1 ? ComponentCatalogView.Page(rawValue: parts[1]) : nil)
        default:
            return nil
        }
    }
}

struct DebugRouteView: View {
    let route: DebugRoute

    var body: some View {
        switch route {
        case .catalog(let page):
            ComponentCatalogView(initialPage: page)
        }
    }
}
#endif
