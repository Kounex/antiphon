import SwiftUI

/// Step 1: Choose the source platform (where the playlist already exists).
struct PlatformPickerStep: View {
    @Bindable var viewModel: LinkWizardViewModel

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Header
            VStack(spacing: 12) {
                Image("AppLogo")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .shadow(color: Color.appleMusicPink.opacity(0.25), radius: 16, y: 4)

                Text("Where does your\nplaylist live?")
                    .font(.appTitle)
                    .foregroundStyle(Color.textPrimary)
                    .multilineTextAlignment(.center)

                Text("We'll sync it to the other platform.")
                    .font(.appBody)
                    .foregroundStyle(Color.textSecondary)
            }

            // Platform cards
            VStack(spacing: 16) {
                PlatformOptionCard(
                    platform: .spotify,
                    isSelected: viewModel.sourcePlatform == .spotify
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.sourcePlatform = .spotify
                    }
                }

                PlatformOptionCard(
                    platform: .appleMusic,
                    isSelected: viewModel.sourcePlatform == .appleMusic
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.sourcePlatform = .appleMusic
                    }
                }
            }
            .padding(.horizontal)

            Spacer()

            // Continue button
            Button {
                viewModel.playlistSearchQuery = ""
                viewModel.advance()
            } label: {
                HStack {
                    Text("Continue")
                    Image(systemName: "arrow.right")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.antiphon)
            .padding(.horizontal)
            .padding(.bottom, 16)
        }
    }
}

// MARK: - Platform Option Card

/// A tappable card representing a music platform choice.
struct PlatformOptionCard: View {
    let platform: Platform
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                // Platform icon
                ZStack {
                    Circle()
                        .fill(platform.color.opacity(0.15))
                        .frame(width: 52, height: 52)

                    Image(systemName: platform.icon)
                        .font(.title2)
                        .foregroundStyle(platform.color)
                }

                // Platform info
                VStack(alignment: .leading, spacing: 4) {
                    Text(platform.rawValue)
                        .font(.appTitle3)
                        .foregroundStyle(Color.textPrimary)

                    Text(platform == .spotify
                         ? "Connect via your Spotify account"
                         : "Uses your Apple Music library")
                        .font(.appCaption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()

                // Selection indicator
                ZStack {
                    Circle()
                        .stroke(isSelected ? platform.color : Color.subtleBorder, lineWidth: 2)
                        .frame(width: 24, height: 24)

                    if isSelected {
                        Circle()
                            .fill(platform.color)
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.cardBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                isSelected ? platform.color.opacity(0.5) : Color.subtleBorder,
                                lineWidth: isSelected ? 1.5 : 1
                            )
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    PlatformPickerStep(viewModel: LinkWizardViewModel())
        .background(Color.appBackground)
}
