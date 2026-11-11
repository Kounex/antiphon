import Foundation

/// DEBUG builds: Spotify failures go to `Documents/sync-diagnostics.log`
/// (pull it with devicectl). Never logs tokens or the Authorization header;
/// request paths and Spotify's error bodies only. Release builds: nothing.
enum SpotifyDebugLog {
    static func line(_ text: @autoclosure () -> String) {
        #if DEBUG
        SyncDiagnostics.log("[Spotify] \(text())")
        #endif
    }

    static func failed(_ request: URLRequest, status: Int, data: Data) {
        line("\(request.httpMethod ?? "GET") \(path(request)) → \(status) \(body(data))")
    }

    static func unreadable(_ request: URLRequest, error: any Error) {
        line("\(request.httpMethod ?? "GET") \(path(request)) → unreadable: \(SpotifyAccessCopy.message(for: error)) \(error)")
    }

    static func body(_ data: Data) -> String {
        String(String(data: data, encoding: .utf8)?.prefix(400) ?? "")
    }

    private static func path(_ request: URLRequest) -> String {
        guard let url = request.url else { return "?" }
        return url.path + (url.query.map { "?\($0)" } ?? "")
    }
}
