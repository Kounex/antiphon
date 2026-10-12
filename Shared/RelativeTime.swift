import Foundation

/// Freshness the way a person says it: "just now", "4 min ago", "3 h ago",
/// "yesterday", "2 days ago".
enum RelativeTime {
    static func text(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        case ..<172_800: return "yesterday"
        default: return "\(Int(seconds / 86_400)) days ago"
        }
    }
}
