import SwiftUI

/// A step-by-step guide explaining how to create a Spotify Developer app
/// and obtain a Client ID for the BYOK (Bring Your Own Key) model.
struct BYOKGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.appBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        // Header
                        VStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.spotifyGreen.opacity(0.12))
                                    .frame(width: 72, height: 72)

                                Image(systemName: "key.fill")
                                    .font(.system(size: 28))
                                    .foregroundStyle(Color.spotifyGreen)
                            }

                            Text("Bring Your Own Key")
                                .font(.appTitle)
                                .foregroundStyle(Color.textPrimary)

                            Text("Antiphon uses your personal Spotify Developer credentials for maximum privacy. Your data never touches our servers.")
                                .font(.appBody)
                                .foregroundStyle(Color.textSecondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                        // Steps
                        VStack(alignment: .leading, spacing: 16) {
                            GuideStep(
                                number: 1,
                                title: "Open Spotify Developer Dashboard",
                                description: "Go to developer.spotify.com and sign in with your Spotify account.",
                                linkText: "developer.spotify.com",
                                linkURL: "https://developer.spotify.com/dashboard"
                            )

                            GuideStep(
                                number: 2,
                                title: "Create an App",
                                description: "Click \"Create an App\". Give it any name (e.g. \"Antiphon\") and description.",
                                linkText: nil,
                                linkURL: nil
                            )

                            GuideStep(
                                number: 3,
                                title: "Set the Redirect URI",
                                description: "In your app settings, add this exact redirect URI:",
                                linkText: nil,
                                linkURL: nil,
                                codeSnippet: AppConstants.Spotify.redirectURI
                            )

                            GuideStep(
                                number: 4,
                                title: "Select Web API",
                                description: "Under \"Which API/SDKs are you planning to use?\", select Web API.",
                                linkText: nil,
                                linkURL: nil
                            )

                            GuideStep(
                                number: 5,
                                title: "Copy your Client ID",
                                description: "Go to your app's overview page. Copy the Client ID and paste it in Antiphon's settings.",
                                linkText: nil,
                                linkURL: nil
                            )
                        }

                        // Privacy note
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .font(.title3)
                                .foregroundStyle(Color.syncSuccess)

                            VStack(alignment: .leading, spacing: 4) {
                                Text("Privacy First")
                                    .font(.appBodyBold)
                                    .foregroundStyle(Color.textPrimary)

                                Text("Your Client ID is stored securely in your device's Keychain. Antiphon communicates directly with Spotify — no intermediary servers.")
                                    .font(.appCaption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                        .glassCard()
                    }
                    .padding()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .presentationBackground(Color.appBackground)
    }
}

// MARK: - Guide Step

struct GuideStep: View {
    let number: Int
    let title: String
    let description: String
    var linkText: String?
    var linkURL: String?
    var codeSnippet: String?

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Step number
            Text("\(number)")
                .font(.appCaptionBold)
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(
                    Circle().fill(AppGradients.brand)
                )

            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)

                Text(description)
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)

                if let codeSnippet {
                    Text(codeSnippet)
                        .font(.appMono)
                        .foregroundStyle(Color.spotifyGreen)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.surfaceElevated)
                        )
                        .textSelection(.enabled)
                }

                if let linkText, let linkURL, let url = URL(string: linkURL) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text(linkText)
                                .font(.appCaptionBold)
                            Image(systemName: "arrow.up.right.square")
                                .font(.appCaption)
                        }
                        .foregroundStyle(Color.syncProgress)
                    }
                }
            }
        }
    }
}
