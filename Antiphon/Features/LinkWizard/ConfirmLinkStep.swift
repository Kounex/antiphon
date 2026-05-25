import SwiftUI

/// Step 4: Review the link configuration and confirm.
///
/// Shows a visual summary of the source → target link, lets the user
/// configure sync direction and auto-monitoring, then creates the SyncPair.
struct ConfirmLinkStep: View {
    @Bindable var viewModel: LinkWizardViewModel

    @State private var isCreating = false
    @State private var showCheckmark = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 28) {
                    // Visual link diagram
                    linkDiagram
                        .padding(.top, 24)

                    // Sync direction picker
                    syncDirectionSection

                    // Auto-monitor toggle
                    monitorSection

                    // Summary
                    summarySection
                }
                .padding(.horizontal)
            }

            // Bottom bar
            bottomBar
        }
    }

    // MARK: - Link Diagram

    private var linkDiagram: some View {
        VStack(spacing: 20) {
            // Source card
            PlaylistSummaryCard(
                platformName: viewModel.sourcePlatform.rawValue,
                platformColor: viewModel.sourcePlatform.color,
                platformIcon: viewModel.sourcePlatform.icon,
                playlistName: viewModel.sourcePlaylistName,
                trackCount: viewModel.sourceTrackCount,
                imageURL: viewModel.sourceImageURL
            )

            // Direction arrow
            VStack(spacing: 4) {
                Image(systemName: viewModel.syncDirection.icon)
                    .font(.title2)
                    .foregroundStyle(Color.textSecondary)
                    .rotationEffect(.degrees(
                        viewModel.syncDirection == .appleToSpotify ? 180 : 0
                    ))

                Text(viewModel.syncDirection.rawValue)
                    .font(.appCaption)
                    .foregroundStyle(Color.textTertiary)
            }

            // Target card
            PlaylistSummaryCard(
                platformName: viewModel.targetPlatform.rawValue,
                platformColor: viewModel.targetPlatform.color,
                platformIcon: viewModel.targetPlatform.icon,
                playlistName: viewModel.targetPlaylistName,
                trackCount: nil,
                imageURL: nil,
                isNew: viewModel.createNewTarget
            )
        }
    }

    // MARK: - Sync Direction

    private var syncDirectionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sync Direction", systemImage: "arrow.left.arrow.right")
                .font(.appCaptionBold)
                .foregroundStyle(Color.textSecondary)

            VStack(spacing: 8) {
                ForEach(SyncDirection.allCases, id: \.self) { direction in
                    DirectionOptionRow(
                        direction: direction,
                        isSelected: viewModel.syncDirection == direction
                    ) {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            viewModel.syncDirection = direction
                        }
                    }
                }
            }
        }
        .glassCard()
    }

    // MARK: - Monitor Toggle

    private var monitorSection: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Auto-Monitor")
                    .font(.appBodyBold)
                    .foregroundStyle(Color.textPrimary)

                Text("Automatically sync changes in the background.")
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            Toggle("", isOn: $viewModel.autoMonitor)
                .labelsHidden()
                .tint(Color.spotifyGreen)
        }
        .glassCard()
    }

    // MARK: - Summary

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("What happens next", systemImage: "info.circle")
                .font(.appCaptionBold)
                .foregroundStyle(Color.textSecondary)

            VStack(alignment: .leading, spacing: 6) {
                SummaryBullet(
                    icon: "1.circle.fill",
                    text: viewModel.createNewTarget
                        ? "A new playlist will be created on \(viewModel.targetPlatform.rawValue)"
                        : "The existing playlists will be linked"
                )
                SummaryBullet(
                    icon: "2.circle.fill",
                    text: "An initial sync will compare all tracks"
                )
                SummaryBullet(
                    icon: "3.circle.fill",
                    text: "Missing tracks will be added to both sides"
                )
                if viewModel.autoMonitor {
                    SummaryBullet(
                        icon: "4.circle.fill",
                        text: "Changes will be synced automatically"
                    )
                }
            }
        }
        .glassCard()
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            Button {
                viewModel.goBack()
            } label: {
                HStack {
                    Image(systemName: "arrow.left")
                    Text("Back")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.secondary)

            Button {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isCreating = true
                }

                // Brief delay for visual feedback, then complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
                        showCheckmark = true
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        viewModel.didComplete = true
                    }
                }
            } label: {
                HStack {
                    if isCreating {
                        if showCheckmark {
                            Image(systemName: "checkmark")
                                .transition(.scale.combined(with: .opacity))
                        } else {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.8)
                        }
                    } else {
                        Image(systemName: "link.badge.plus")
                    }
                    Text(isCreating ? (showCheckmark ? "Linked!" : "Creating…") : "Create Link")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.antiphon)
            .disabled(isCreating)
        }
        .padding()
    }
}

// MARK: - Playlist Summary Card

struct PlaylistSummaryCard: View {
    let platformName: String
    let platformColor: Color
    let platformIcon: String
    let playlistName: String
    let trackCount: Int?
    let imageURL: String?
    var isNew: Bool = false

    var body: some View {
        HStack(spacing: 14) {
            // Artwork or platform icon
            if let imageURL {
                TrackArtworkView(url: imageURL, size: 56, cornerRadius: 12)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(platformColor.opacity(0.12))
                        .frame(width: 56, height: 56)

                    Image(systemName: platformIcon)
                        .font(.title2)
                        .foregroundStyle(platformColor)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(playlistName)
                        .font(.appBodyBold)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)

                    if isNew {
                        Text("NEW")
                            .font(.appMicro)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill(platformColor)
                            )
                    }
                }

                HStack(spacing: 4) {
                    Text(platformName)
                        .font(.appCaption)
                        .foregroundStyle(platformColor)

                    if let trackCount, trackCount > 0 {
                        Text("•")
                            .foregroundStyle(Color.textTertiary)
                        Text("\(trackCount) tracks")
                            .font(.appCaption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            Spacer()
        }
        .glassCard()
    }
}

// MARK: - Direction Option Row

struct DirectionOptionRow: View {
    let direction: SyncDirection
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: direction.icon)
                    .font(.appBody)
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textTertiary)
                    .frame(width: 24)

                Text(direction.rawValue)
                    .font(.appBody)
                    .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)

                Spacer()

                ZStack {
                    Circle()
                        .stroke(isSelected ? Color.syncProgress : Color.subtleBorder, lineWidth: 2)
                        .frame(width: 22, height: 22)

                    if isSelected {
                        Circle()
                            .fill(Color.syncProgress)
                            .frame(width: 12, height: 12)
                    }
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Color.syncProgress.opacity(0.06) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Summary Bullet

struct SummaryBullet: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.appCaption)
                .foregroundStyle(Color.textTertiary)
                .frame(width: 20)

            Text(text)
                .font(.appCaption)
                .foregroundStyle(Color.textSecondary)
        }
    }
}
