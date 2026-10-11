#if DEBUG
import SwiftData
import Synchronization

/// The store a self-test is running against, so a notification answered
/// during the `ask` scenario writes there and not into the app's store.
enum SelfTestStore {
    static let container = Mutex<ModelContainer?>(nil)
}
#endif
