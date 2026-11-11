import Foundation

/// Sharing a Spotify client ID with someone, so they can skip the developer
/// dashboard. Spotify lets up to five accounts use one development-mode
/// app; its owner adds each one under Users Management. A client ID isn't a
/// secret: sign-in is PKCE, and the tokens stay on each person's phone.
enum SpotifyInvite {
    static let scheme = "antiphon"
    static let host = "connect"

    /// `antiphon://connect?client_id=…`, or `nil` for anything that isn't a client ID.
    static func link(clientId: String) -> URL? {
        guard case .valid(let id) = SpotifyClientID.check(clientId) else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "client_id", value: id)]
        return components.url
    }

    /// The client ID an invite link carries. Every other link (the Spotify
    /// sign-in callback, widget links) gives `nil`.
    static func clientId(from url: URL) -> String? {
        guard url.scheme?.lowercased() == scheme, url.host?.lowercased() == host,
              let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "client_id" })?.value,
              case .valid(let id) = SpotifyClientID.check(value) else { return nil }
        return id
    }

    /// What goes into the share sheet.
    static func message(clientId: String) -> String? {
        guard let link = link(clientId: clientId) else { return nil }
        return "Use my Spotify key for Antiphon. First send me the email address of your Spotify account: "
            + "I have to add it under Users Management on developer.spotify.com. Then open this on your iPhone:\n\(link.absoluteString)"
    }

    static let sharingNote = "Up to 5 people can use one client ID, and they skip the developer dashboard. "
        + "Add each person's Spotify email under Users Management on developer.spotify.com first. "
        + "Spotify doesn't say whether they need Premium too."

    static let invitedNote = "This client ID came from an invite link. Its owner has to add your Spotify email "
        + "under Users Management before you connect."
}
