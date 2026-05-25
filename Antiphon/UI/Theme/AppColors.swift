import SwiftUI

// MARK: - Brand Colors

extension Color {
    /// Spotify brand green
    static let spotifyGreen = Color(red: 0.11, green: 0.73, blue: 0.33)

    /// Apple Music gradient colors
    static let appleMusicPink = Color(red: 0.98, green: 0.22, blue: 0.40)
    static let appleMusicRed = Color(red: 0.89, green: 0.09, blue: 0.27)

    // MARK: - App Primary Palette

    /// Deep navy-purple background
    static let appBackground = Color(red: 0.07, green: 0.07, blue: 0.12)

    /// Slightly lighter card background
    static let cardBackground = Color(red: 0.11, green: 0.11, blue: 0.18)

    /// Elevated surface (modals, sheets)
    static let surfaceElevated = Color(red: 0.15, green: 0.15, blue: 0.22)

    /// Subtle border / separator
    static let subtleBorder = Color.white.opacity(0.08)

    // MARK: - Text Colors

    /// Primary text — bright white
    static let textPrimary = Color.white

    /// Secondary text — muted
    static let textSecondary = Color.white.opacity(0.6)

    /// Tertiary text — very muted
    static let textTertiary = Color.white.opacity(0.35)

    // MARK: - Status Colors

    /// Success / synced
    static let syncSuccess = Color(red: 0.20, green: 0.78, blue: 0.35)

    /// Warning / partial sync
    static let syncWarning = Color(red: 1.0, green: 0.76, blue: 0.03)

    /// Error / failed
    static let syncError = Color(red: 1.0, green: 0.27, blue: 0.27)

    /// In progress / syncing
    static let syncProgress = Color(red: 0.35, green: 0.60, blue: 1.0)

}

// MARK: - Gradients

enum AppGradients {
    /// A blended Spotify → Apple Music gradient
    static let brand = LinearGradient(
        colors: [.spotifyGreen, Color(red: 0.30, green: 0.50, blue: 0.90), .appleMusicPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Subtle glass background gradient
    static let glass = LinearGradient(
        colors: [
            Color.white.opacity(0.12),
            Color.white.opacity(0.04),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

// MARK: - Platform-Specific Colors

/// Represents a music streaming platform supported by Antiphon.
enum Platform: String, CaseIterable, Codable {
    case spotify = "Spotify"
    case appleMusic = "Apple Music"

    /// The brand color for this platform.
    var color: Color {
        switch self {
        case .spotify: return .spotifyGreen
        case .appleMusic: return .appleMusicPink
        }
    }

    /// SF Symbol name representing this platform.
    var icon: String {
        switch self {
        case .spotify: return "waveform.circle.fill"
        case .appleMusic: return "music.note.list"
        }
    }

    /// A branded gradient for this platform.
    var gradient: LinearGradient {
        switch self {
        case .spotify:
            return LinearGradient(
                colors: [.spotifyGreen, .spotifyGreen.opacity(0.7)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .appleMusic:
            return LinearGradient(
                colors: [.appleMusicPink, .appleMusicRed],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}
