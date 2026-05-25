import Foundation
import Security

/// A lightweight wrapper around the iOS Keychain for securely storing Spotify tokens.
///
/// All methods are static and use `kSecAttrAccessibleAfterFirstUnlock` so tokens
/// remain available during background sync operations.
enum KeychainManager {

    // MARK: - Errors

    enum KeychainError: LocalizedError {
        case duplicateItem
        case itemNotFound
        case unexpectedStatus(OSStatus)
        case dataConversionError

        var errorDescription: String? {
            switch self {
            case .duplicateItem: return "Item already exists in Keychain"
            case .itemNotFound: return "Item not found in Keychain"
            case .unexpectedStatus(let status): return "Keychain error: \(status)"
            case .dataConversionError: return "Failed to convert Keychain data"
            }
        }
    }

    // MARK: - Keys

    enum Key: String {
        case spotifyAccessToken = "com.kounex.antiphon.spotify.accessToken"
        case spotifyRefreshToken = "com.kounex.antiphon.spotify.refreshToken"
        case spotifyTokenExpiry = "com.kounex.antiphon.spotify.tokenExpiry"
        case spotifyClientId = "com.kounex.antiphon.spotify.clientId"
    }

    // MARK: - CRUD

    /// Saves a string value to the Keychain, replacing any existing item for the given key.
    static func save(_ value: String, for key: Key) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.dataConversionError
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        // Delete existing item first
        SecItemDelete(query as CFDictionary)

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Loads a string value from the Keychain, returning `nil` if the key doesn't exist.
    static func load(_ key: Key) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
              let data = result as? Data,
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }

        return string
    }

    /// Deletes the item for the given key from the Keychain.
    static func delete(_ key: Key) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key.rawValue
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Removes all Spotify-related tokens from the Keychain.
    static func deleteAll() {
        for key in [Key.spotifyAccessToken, .spotifyRefreshToken, .spotifyTokenExpiry, .spotifyClientId] {
            delete(key)
        }
    }
}
