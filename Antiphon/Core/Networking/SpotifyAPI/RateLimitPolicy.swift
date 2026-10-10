import Foundation

/// How long to wait after a Spotify 429 before retrying, if at all.
///
/// Spotify can answer with a `Retry-After` of minutes or hours. Sleeping
/// that long freezes a sync with no feedback, so anything over `maxWait`
/// fails straight away as `rateLimited` and the person is told to try later.
enum RateLimitPolicy {
    static let maxWait: TimeInterval = 30
    static let maxRetries = 3
    static let defaultWait: TimeInterval = 5

    /// Seconds to wait, or `nil` to give up now.
    static func delay(retryAfterHeader: String?, attempt: Int) -> TimeInterval? {
        guard attempt < maxRetries else { return nil }
        let wait = retryAfterHeader.flatMap(TimeInterval.init) ?? defaultWait
        return wait <= maxWait ? wait : nil
    }
}
