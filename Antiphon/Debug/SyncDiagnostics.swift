#if DEBUG
import Foundation
import Synchronization

/// A plain log of what a continued sync went through, for reading off a
/// device (`Documents/sync-diagnostics.log`). DEBUG only.
enum SyncDiagnostics {
    private static let lock = Mutex(())

    static func log(_ line: String) {
        let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
        let text = "\(stamp) \(line)\n"
        print("[SyncDiagnostics] \(line)")
        lock.withLock { _ in
            guard let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
            let file = folder.appending(path: "sync-diagnostics.log")
            if let handle = try? FileHandle(forWritingTo: file) {
                handle.seekToEndOfFile()
                handle.write(Data(text.utf8))
                try? handle.close()
            } else {
                try? Data(text.utf8).write(to: file)
            }
        }
    }
}
#endif
