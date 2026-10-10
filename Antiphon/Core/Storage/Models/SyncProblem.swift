import Foundation
import SwiftData

/// Something Antiphon can't fix alone, shown on the Problems screen.
///
/// Background runs create these so the notification and the Problems list
/// agree. `pair == nil` means the problem affects every seam (a sign-out).
@Model
final class SyncProblem {
    var id: UUID
    var kind: ProblemKind
    var platform: Platform?
    var pair: SyncPair?
    var message: String
    var firstSeenAt: Date
    /// When Antiphon will try again on its own, for temporary problems.
    var retryAt: Date?
    var resolvedAt: Date?

    init(kind: ProblemKind, platform: Platform?, message: String, retryAt: Date? = nil) {
        self.id = UUID()
        self.kind = kind
        self.platform = platform
        self.message = message
        self.firstSeenAt = Date()
        self.retryAt = retryAt
    }
}

enum ProblemKind: String, Codable, Sendable {
    case signedOut
    case playlistDeleted
    case rateLimited
    case writeRefused
    case subscriptionLapsed
}
