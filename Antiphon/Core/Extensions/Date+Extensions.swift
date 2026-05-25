import Foundation

extension Date {
    /// Returns a human-readable relative description (e.g. "2 min. ago").
    var relativeDescription: String {
        let diff = abs(Date().timeIntervalSince(self))
        if diff < 60 {
            return "Just now"
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }

    /// Returns a short date+time string (e.g. "5/24/26, 11:49 AM").
    var shortDescription: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: self)
    }
}
