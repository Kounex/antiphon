import Foundation

// MARK: - Auth Responses

struct SpotifyTokenResponse: Codable {
    let accessToken: String
    let tokenType: String
    let expiresIn: Int
    let refreshToken: String?
    let scope: String?
    
    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
        case scope
    }
}

// MARK: - Pagination

struct SpotifyPagingObject<T: Decodable>: Decodable {
    let href: String
    let items: [T]
    let limit: Int
    let next: String?
    let offset: Int
    let previous: String?
    let total: Int
}

// MARK: - Playlist

struct SpotifyPlaylist: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let isPublic: Bool?
    let collaborative: Bool
    let owner: SpotifyUser
    let snapshotId: String
    /// Item count reference. Spotify's February 2026 Web API change renamed
    /// the JSON key from `tracks` to `items`; both are accepted so the decode
    /// survives either shape.
    let tracks: SpotifyPlaylistTracksRef
    let images: [SpotifyImage]?
    let uri: String
    let externalUrls: SpotifyExternalURLs
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, collaborative, owner, items, tracks, images, uri
        case isPublic = "public"
        case snapshotId = "snapshot_id"
        case externalUrls = "external_urls"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        description = try container.decodeIfPresent(String.self, forKey: .description)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic)
        collaborative = try container.decode(Bool.self, forKey: .collaborative)
        owner = try container.decode(SpotifyUser.self, forKey: .owner)
        snapshotId = try container.decode(String.self, forKey: .snapshotId)
        tracks = try container.decodeIfPresent(SpotifyPlaylistTracksRef.self, forKey: .items)
            ?? container.decode(SpotifyPlaylistTracksRef.self, forKey: .tracks)
        images = try container.decodeIfPresent([SpotifyImage].self, forKey: .images)
        uri = try container.decode(String.self, forKey: .uri)
        externalUrls = try container.decode(SpotifyExternalURLs.self, forKey: .externalUrls)
    }

    /// Whether the current user can read and write this playlist's items.
    /// Since February 2026 Spotify returns 403 for item reads and writes on
    /// playlists the user merely follows.
    func isEditable(byUserId userId: String) -> Bool {
        owner.id == userId || collaborative
    }
}

struct SpotifyPlaylistTracksRef: Codable {
    let href: String
    let total: Int
}

struct SpotifyUser: Codable {
    let id: String
    let displayName: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
    }
}

struct SpotifyImage: Codable {
    let url: String
    let height: Int?
    let width: Int?
}

struct SpotifyExternalURLs: Codable {
    let spotify: String?
}

// MARK: - Track

struct SpotifyPlaylistItem: Decodable {
    let addedAt: String?
    let addedBy: SpotifyUser?
    let isLocal: Bool?
    /// The track or episode. Spotify's February 2026 Web API change renamed
    /// the JSON key from `track` to `item` (`track` is deprecated); both are
    /// accepted.
    let track: SpotifyTrack?
    
    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case addedBy = "added_by"
        case isLocal = "is_local"
        case item, track
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        addedAt = try container.decodeIfPresent(String.self, forKey: .addedAt)
        addedBy = try container.decodeIfPresent(SpotifyUser.self, forKey: .addedBy)
        isLocal = try container.decodeIfPresent(Bool.self, forKey: .isLocal)
        track = try container.decodeIfPresent(SpotifyTrack.self, forKey: .item)
            ?? container.decodeIfPresent(SpotifyTrack.self, forKey: .track)
    }
}

/// A track object as returned by the Spotify Web API.
///
/// Playlist item endpoints can also return podcast *episode* objects in the
/// same `item` slot. Episodes share the fields below but have no `artists`
/// array, so `artists` must stay optional or a single episode fails the decode
/// of the entire page. Non-track items are filtered out in
/// `SpotifyAPIClient.getPlaylistTracks`.
struct SpotifyTrack: Codable, Identifiable {
    let id: String?
    let name: String
    let uri: String
    let durationMs: Int
    let explicit: Bool?
    let popularity: Int?
    let album: SpotifyAlbum?
    let artists: [SpotifyArtist]?
    let externalIds: SpotifyExternalIds?
    let externalUrls: SpotifyExternalURLs?
    /// "track", "episode", etc.
    let type: String
    
    enum CodingKeys: String, CodingKey {
        case id, name, uri, explicit, popularity, album, artists, type
        case durationMs = "duration_ms"
        case externalIds = "external_ids"
        case externalUrls = "external_urls"
    }
    
    /// The ISRC code for this track, if available.
    var isrc: String? {
        externalIds?.isrc
    }
    
    /// Primary artist name.
    var primaryArtist: String {
        artists?.first?.name ?? "Unknown Artist"
    }
}

struct SpotifyAlbum: Codable {
    let id: String
    let name: String
    let images: [SpotifyImage]?
    let releaseDate: String?
    
    enum CodingKeys: String, CodingKey {
        case id, name, images
        case releaseDate = "release_date"
    }
}

struct SpotifyArtist: Codable {
    let id: String?
    let name: String
}

struct SpotifyExternalIds: Codable {
    let isrc: String?
    let ean: String?
    let upc: String?
}

// MARK: - Search

struct SpotifySearchResponse: Decodable {
    let tracks: SpotifyPagingObject<SpotifyTrack>?
}

// MARK: - Playlist Modification

struct SpotifyAddTracksRequest: Codable {
    let uris: [String]
    let position: Int?
}

/// Moves `rangeLength` items starting at `rangeStart` before `insertBefore`.
struct SpotifyReorderTracksRequest: Codable {
    let rangeStart: Int
    let insertBefore: Int
    let rangeLength: Int

    enum CodingKeys: String, CodingKey {
        case rangeStart = "range_start"
        case insertBefore = "insert_before"
        case rangeLength = "range_length"
    }
}

struct SpotifyRemoveTracksRequest: Codable {
    let items: [SpotifyTrackReference]
    let snapshotId: String?
    
    enum CodingKeys: String, CodingKey {
        case items
        case snapshotId = "snapshot_id"
    }
}

struct SpotifyTrackReference: Codable {
    let uri: String
}

struct SpotifySnapshotResponse: Codable {
    let snapshotId: String
    
    enum CodingKeys: String, CodingKey {
        case snapshotId = "snapshot_id"
    }
}

struct SpotifyCreatePlaylistRequest: Codable {
    let name: String
    let description: String?
    let isPublic: Bool
    let collaborative: Bool
    
    enum CodingKeys: String, CodingKey {
        case name, description, collaborative
        case isPublic = "public"
    }
}

// MARK: - User Profile

struct SpotifyUserProfile: Codable {
    let id: String
    let displayName: String?
    let email: String?
    let images: [SpotifyImage]?
    let product: String?  // "premium", "free", etc.
    
    enum CodingKeys: String, CodingKey {
        case id, email, images, product
        case displayName = "display_name"
    }
}
