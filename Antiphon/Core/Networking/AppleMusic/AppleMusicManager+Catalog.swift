import Foundation
import MusicKit

extension AppleMusicManager {
    /// Every catalog release carrying this ISRC (the original album and any
    /// compilations), so the matcher can pick the original.
    func searchAllByISRC(_ isrc: String) async throws -> [Song] {
        guard MusicAuthorization.currentStatus == .authorized else { throw AppleMusicError.notAuthorized }
        let request = MusicCatalogResourceRequest<Song>(matching: \.isrc, equalTo: isrc)
        return Array(try await request.response().items)
    }
}
