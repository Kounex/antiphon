import SwiftUI
import MusicKit

/// The main settings view with sections for platform connections,
/// sync preferences, and app information.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SpotifyAuthManager.self) private var spotifyAuth
    @Environment(\.modelContext) private var modelContext

    @State private var appleMusicManager = AppleMusicManager()
    @State private var showBYOKGuide = false
    @State private var showResetConfirmation = false
    @AppStorage("syncIntervalMinutes") private var syncIntervalMinutes = AppConstants.Sync.defaultSyncIntervalMinutes

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // App header
                        appHeader
                            .padding(.top, 8)

                        // Platform connections
                        platformSection

                        // Sync preferences
                        syncPreferencesSection

                        // Data management
                        dataSection

                        // About
                        aboutSection
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 32)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Settings")
                        .font(.appTitle3)
                        .foregroundStyle(Color.textPrimary)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .sheet(isPresented: $showBYOKGuide) {
                BYOKGuideView()
            }
            .alert("Reset All Data?", isPresented: $showResetConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Reset", role: .destructive) {
                    resetAllData()
                }
            } message: {
                Text("This will unlink all playlists, clear sync history, and sign out of Spotify. Your playlists on both platforms will not be affected.")
            }
        }
        .presentationBackground(Color.appBackground)
    }

    // MARK: - App Header

    private var appHeader: some View {
        VStack(spacing: 12) {
            Image("AppLogo")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color.appleMusicPink.opacity(0.2), radius: 12, y: 4)

            Text("Antiphon")
                .font(.appTitle)
                .foregroundStyle(Color.textPrimary)

            Text("v1.0.0")
                .font(.appCaption)
                .foregroundStyle(Color.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    // MARK: - Platform Connections

    private var platformSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Connections", icon: "link")

            // Spotify
            SpotifyConnectionCard(
                spotifyAuth: spotifyAuth,
                onSetupBYOK: { showBYOKGuide = true }
            )

            // Apple Music
            AppleMusicConnectionCard(appleMusicManager: appleMusicManager)
        }
    }

    // MARK: - Sync Preferences

    private var syncPreferencesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Sync", icon: "arrow.triangle.2.circlepath")

            VStack(spacing: 0) {
                // Sync interval
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Background Interval")
                            .font(.appBody)
                            .foregroundStyle(Color.textPrimary)
                        Text("How often to check for changes")
                            .font(.appCaption)
                            .foregroundStyle(Color.textTertiary)
                    }

                    Spacer()

                    Picker("", selection: $syncIntervalMinutes) {
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                        Text("1 hour").tag(60)
                        Text("4 hours").tag(240)
                    }
                    .tint(Color.textSecondary)
                }
                .padding(14)
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.subtleBorder, lineWidth: 1)
                    )
            )

            // Safety threshold description (non-interactive, footer style)
            HStack(spacing: 6) {
                Image(systemName: "shield.checkered")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncSuccess)
                Text("Safety threshold will abort a sync if more than \(Int(AppConstants.Sync.safetyThresholdPercentage * 100))% of tracks would be removed, protecting against API failures.")
                    .font(.appCaption)
                    .foregroundStyle(Color.textTertiary)
            }
            .padding(.horizontal, 4)
        }
    }

    // MARK: - Data Section

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Data", icon: "externaldrive")

            Button {
                showResetConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise")
                    Text("Reset All Data")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.appCaption)
                        .foregroundStyle(Color.textTertiary)
                }
                .font(.appBody)
                .foregroundStyle(Color.syncError)
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.cardBackground)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.subtleBorder, lineWidth: 1)
                        )
                )
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "About", icon: "info.circle")

            VStack(spacing: 0) {
                AboutRow(label: "Version", value: "1.0.0")
                Divider().background(Color.subtleBorder)
                AboutRow(label: "iOS", value: UIDevice.current.systemVersion)
                Divider().background(Color.subtleBorder)
                AboutRow(label: "Sync Engine", value: "ISRC + Fuzzy Match")
            }
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(Color.subtleBorder, lineWidth: 1)
                    )
            )
        }
    }

    // MARK: - Helpers

    private func resetAllData() {
        spotifyAuth.logout()
        KeychainManager.deleteAll()
        
        // Actually delete the SyncPairs from the database
        do {
            try modelContext.delete(model: SyncPair.self)
            try modelContext.save()
        } catch {
            print("Failed to delete all SyncPairs: \(error.localizedDescription)")
        }
    }
}

// MARK: - Section Header

struct SectionHeader: View {
    let title: String
    let icon: String

    var body: some View {
        Label(title, systemImage: icon)
            .font(.appCaptionBold)
            .foregroundStyle(Color.textSecondary)
            .textCase(.uppercase)
    }
}

// MARK: - About Row

struct AboutRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.appBody)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text(value)
                .font(.appBody)
                .foregroundStyle(Color.textTertiary)
        }
        .padding(14)
    }
}
