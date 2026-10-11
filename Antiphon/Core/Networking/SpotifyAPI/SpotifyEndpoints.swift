import Foundation

enum SpotifyEndpoint {
    case me
    case user(id: String)
    case myPlaylists(limit: Int, offset: Int)
    case playlistTracks(playlistId: String, limit: Int, offset: Int, market: String?)
    case addTracks(playlistId: String)
    case removeTracks(playlistId: String)
    case reorderTracks(playlistId: String)
    case createPlaylist
    case searchByQuery(query: String, type: String, market: String?, limit: Int)
    case uploadPlaylistImage(playlistId: String)
    
    var path: String {
        switch self {
        case .me:
            return "/me"
        case .user(let id):
            return "/users/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)"
        case .myPlaylists:
            return "/me/playlists"
        case .playlistTracks(let playlistId, _, _, _):
            return "/playlists/\(playlistId)/items"
        case .addTracks(let playlistId):
            return "/playlists/\(playlistId)/items"
        case .removeTracks(let playlistId), .reorderTracks(let playlistId):
            return "/playlists/\(playlistId)/items"
        case .createPlaylist:
            return "/me/playlists"
        case .searchByQuery:
            return "/search"
        case .uploadPlaylistImage(let playlistId):
            return "/playlists/\(playlistId)/images"
        }
    }
    
    var queryItems: [URLQueryItem] {
        switch self {
        case .me, .user:
            return []
        case .myPlaylists(let limit, let offset):
            return [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
        case .playlistTracks(_, let limit, let offset, let market):
            var items = [
                URLQueryItem(name: "limit", value: "\(limit)"),
                URLQueryItem(name: "offset", value: "\(offset)")
            ]
            if let market { items.append(URLQueryItem(name: "market", value: market)) }
            return items
        case .addTracks, .removeTracks, .reorderTracks, .createPlaylist, .uploadPlaylistImage:
            return []
        case .searchByQuery(let query, let type, let market, let limit):
            var items = [
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "type", value: type),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            if let market { items.append(URLQueryItem(name: "market", value: market)) }
            return items
        }
    }
    
    var httpMethod: String {
        switch self {
        case .me, .user, .myPlaylists, .playlistTracks, .searchByQuery:
            return "GET"
        case .addTracks, .createPlaylist:
            return "POST"
        case .removeTracks:
            return "DELETE"
        case .uploadPlaylistImage, .reorderTracks:
            return "PUT"
        }
    }
    
    func url(baseURL: String = AppConstants.Spotify.apiBaseURL) -> URL? {
        var components = URLComponents(string: baseURL + path)
        let items = queryItems
        if !items.isEmpty {
            components?.queryItems = items
        }
        return components?.url
    }
}
