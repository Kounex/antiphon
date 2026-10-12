import Foundation
import SwiftData
import Testing
@testable import Antiphon

@Suite("Store changes", .serialized)
@MainActor
struct StoreChangesTests {
    @Test("A burst of saves (a sync saving per track) becomes one redraw per interval")
    func coalesces() async throws {
        let changes = StoreChanges(interval: .milliseconds(30), observeSaves: false)
        for _ in 0..<5 { changes.noteChange() }
        #expect(changes.revision == 0)
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.revision == 1)
        changes.noteChange()
        try await Task.sleep(for: .milliseconds(150))
        #expect(changes.revision == 2)
    }

    @Test("Any save in the app's store counts, whichever context made it")
    func followsSaves() async throws {
        let changes = StoreChanges(interval: .milliseconds(10))
        let container = try SharedModelContainer.make(inMemory: true)
        let context = ModelContext(container)
        context.insert(SyncPair(spotifyPlaylistId: "s", spotifyPlaylistName: "A", appleMusicPlaylistId: "a",
                                appleMusicPlaylistName: "A", syncDirection: .spotifyToApple))
        try context.save()
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes.revision >= 1)
    }
}
