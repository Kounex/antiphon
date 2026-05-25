import SwiftUI
import AuthenticationServices

/// Card showing Spotify connection status with login/logout controls
/// and the BYOK (Bring Your Own Key) Client ID input.
struct SpotifyConnectionCard: View {
    @Bindable var spotifyAuth: SpotifyAuthManager
    let onSetupBYOK: () -> Void

    @State private var clientIdInput: String = ""
    @State private var isLoggingIn = false

    var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack(spacing: 12) {
                PlatformBadge(platform: .spotify, size: .regular)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Spotify")
                        .font(.appBodyBold)
                        .foregroundStyle(Color.textPrimary)

                    if spotifyAuth.isAuthenticated {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color.syncSuccess)
                                .frame(width: 6, height: 6)
                            Text(spotifyAuth.userProfile?.displayName ?? "Connected")
                                .font(.appCaption)
                                .foregroundStyle(Color.syncSuccess)
                        }
                    } else {
                        Text("Not connected")
                            .font(.appCaption)
                            .foregroundStyle(Color.textTertiary)
                    }
                }

                Spacer()

                if spotifyAuth.isAuthenticated {
                    Button("Sign Out") {
                        spotifyAuth.logout()
                    }
                    .font(.appCaption)
                    .foregroundStyle(Color.syncError)
                }
            }

            // Client ID section
            if !spotifyAuth.isAuthenticated {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Client ID")
                            .font(.appCaptionBold)
                            .foregroundStyle(Color.textSecondary)

                        Spacer()

                        Button {
                            onSetupBYOK()
                        } label: {
                            Text("How to get one?")
                                .font(.appCaption)
                                .foregroundStyle(Color.syncProgress)
                        }
                    }

                    HStack(spacing: 8) {
                        TextField("Paste your Spotify Client ID", text: $clientIdInput)
                            .font(.appMono)
                            .foregroundStyle(Color.textPrimary)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                            .padding(10)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.surfaceElevated)
                            )

                        Button {
                            spotifyAuth.clientId = clientIdInput
                        } label: {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(
                                    clientIdInput.count >= 20
                                        ? Color.spotifyGreen : Color.textTertiary
                                )
                        }
                        .disabled(clientIdInput.count < 20)
                    }
                }

                // Login button
                if spotifyAuth.clientId != nil {
                    Button {
                        Task { await login() }
                    } label: {
                        HStack {
                            if isLoggingIn {
                                ProgressView().tint(.white).scaleEffect(0.8)
                            } else {
                                Image(systemName: "person.crop.circle.badge.checkmark")
                            }
                            Text(isLoggingIn ? "Connecting…" : "Connect Spotify")
                        }
                        .frame(maxWidth: .infinity)
                        .font(.appBodyBold)
                        .foregroundStyle(.white)
                        .padding(.vertical, 12)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.spotifyGreen)
                        )
                    }
                    .disabled(isLoggingIn)
                }

                if let error = spotifyAuth.authError {
                    Text(error)
                        .font(.appCaption)
                        .foregroundStyle(Color.syncError)
                }
            }
        }
        .glassCard()
        .onAppear {
            clientIdInput = spotifyAuth.clientId ?? ""
        }
    }

    @MainActor
    private func login() async {
        isLoggingIn = true
        defer { isLoggingIn = false }

        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first else { return }

        do {
            try await spotifyAuth.startLogin(presentingFrom: window)
        } catch {
            spotifyAuth.authError = error.localizedDescription
        }
    }
}

// MARK: - Apple Music Connection Card

struct AppleMusicConnectionCard: View {
    @Bindable var appleMusicManager: AppleMusicManager

    var body: some View {
        HStack(spacing: 12) {
            PlatformBadge(platform: .appleMusic, size: .regular)

            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Music")
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)

                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 6, height: 6)
                    Text(statusText)
                        .font(.appCaption)
                        .foregroundStyle(statusColor)
                }
            }

            Spacer()

            if !appleMusicManager.isAuthorized {
                Button {
                    Task {
                        await appleMusicManager.requestAuthorization()
                    }
                } label: {
                    Text("Authorize")
                        .font(.appCaptionBold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(Color.appleMusicPink)
                        )
                }
            }
        }
        .glassCard()
        .onAppear {
            appleMusicManager.refreshStatus()
        }
    }

    private var statusColor: Color {
        switch appleMusicManager.authorizationStatus {
        case .authorized: return .syncSuccess
        case .denied: return .syncError
        case .restricted: return .syncWarning
        case .notDetermined: return .textTertiary
        @unknown default: return .textTertiary
        }
    }

    private var statusText: String {
        switch appleMusicManager.authorizationStatus {
        case .authorized: return "Authorized"
        case .denied: return "Denied — enable in Settings"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not yet authorized"
        @unknown default: return "Unknown"
        }
    }
}
