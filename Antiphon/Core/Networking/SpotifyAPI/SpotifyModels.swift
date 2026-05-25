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

struct SpotifyPagingObject<T: Codable>: Codable {
    let href: String
    let items: [T]
    let limit: Int
    let next: String?
    let offset: Int
    let previous: String?
    let total: Int
}

// MARK: - Playlist

struct SpotifyPlaylist: Codable, Identifiable {
    let id: String
    let name: String
    let description: String?
    let isPublic: Bool?
    let collaborative: Bool
    let owner: SpotifyUser
    let snapshotId: String
    let tracks: SpotifyPlaylistTracksRef
    let images: [SpotifyImage]?
    let uri: String
    let externalUrls: SpotifyExternalURLs
    
    enum CodingKeys: String, CodingKey {
        case id, name, description, collaborative, owner, tracks, images, uri
        case isPublic = "public"
        case snapshotId = "snapshot_id"
        case externalUrls = "external_urls"
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

struct SpotifyPlaylistItem: Codable {
    let addedAt: String?
    let addedBy: SpotifyUser?
    let isLocal: Bool?
    let track: SpotifyTrack?
    
    enum CodingKeys: String, CodingKey {
        case addedAt = "added_at"
        case addedBy = "added_by"
        case isLocal = "is_local"
        case track
    }
}

struct SpotifyTrack: Codable, Identifiable {
    let id: String?
    let name: String
    let uri: String
    let durationMs: Int
    let explicit: Bool?
    let popularity: Int?
    let album: SpotifyAlbum?
    let artists: [SpotifyArtist]
    let externalIds: SpotifyExternalIds?
    let externalUrls: SpotifyExternalURLs?
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
        artists.first?.name ?? "Unknown Artist"
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

struct SpotifySearchResponse: Codable {
    let tracks: SpotifyPagingObject<SpotifyTrack>?
}

// MARK: - Playlist Modification

struct SpotifyAddTracksRequest: Codable {
    let uris: [String]
    let position: Int?
}

struct SpotifyRemoveTracksRequest: Codable {
    let tracks: [SpotifyTrackReference]
    let snapshotId: String?
    
    enum CodingKeys: String, CodingKey {
        case tracks
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
