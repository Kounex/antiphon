import Foundation
import SwiftData

/// An open problem, as a value.
struct ProblemRecord: Identifiable, Hashable, Sendable {
    let id: UUID
    let kind: ProblemKind
    let platform: Platform?
    let seamId: UUID?
    let message: String
    let firstSeenAt: Date
    let retryAt: Date?
}

protocol ProblemsRepository: Sendable {
    /// Unresolved problems, oldest first.
    func problems() async throws -> [ProblemRecord]
}

extension SwiftDataSeamRepository: ProblemsRepository {
    func problems() async throws -> [ProblemRecord] {
        let context = ModelContext(modelContainerForReview)
        let open = try context.fetch(FetchDescriptor<SyncProblem>(
            predicate: #Predicate { $0.resolvedAt == nil }, sortBy: [SortDescriptor(\.firstSeenAt)]
        ))
        return open.map {
            ProblemRecord(id: $0.id, kind: $0.kind, platform: $0.platform, seamId: $0.pair?.id,
                          message: $0.message, firstSeenAt: $0.firstSeenAt, retryAt: $0.retryAt)
        }
    }
}
