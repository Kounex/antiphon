import Foundation
import Testing
@testable import Antiphon

@Suite("Spotify rate-limit waits")
struct RateLimitPolicyTests {
    @Test("Short waits are honored")
    func shortWait() {
        #expect(RateLimitPolicy.delay(retryAfterHeader: "3", attempt: 0) == 3)
        #expect(RateLimitPolicy.delay(retryAfterHeader: nil, attempt: 0) == 5)
    }

    @Test("Long waits give up at once instead of sleeping")
    func longWait() {
        #expect(RateLimitPolicy.delay(retryAfterHeader: "31", attempt: 0) == nil)
        #expect(RateLimitPolicy.delay(retryAfterHeader: "86400", attempt: 0) == nil)
    }

    @Test("After three retries it gives up")
    func attempts() {
        #expect(RateLimitPolicy.delay(retryAfterHeader: "1", attempt: 3) == nil)
    }
}
