import SwiftUI

/// An animated indicator that displays the current sync status with a colorized icon and label text.
struct SyncStatusIndicator: View {
    let status: SyncResultStatus?
    let message: String?

    @State private var rotationAngle: Double = 0.0

    var body: some View {
        HStack(spacing: 6) {
            statusIcon
            statusText
        }
    }

    // MARK: - Status Icon

    @ViewBuilder
    private var statusIcon: some View {
        Image(systemName: statusIconName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(statusColor)
            .rotationEffect(.degrees(rotationAngle))
            .onAppear {
                startRotationIfNeeded()
            }
            .onChange(of: status) { _, _ in
                startRotationIfNeeded()
            }
    }

    private func startRotationIfNeeded() {
        if status == .inProgress {
            rotationAngle = 0.0
            withAnimation(.linear(duration: 2.0).repeatForever(autoreverses: false)) {
                rotationAngle = 360.0
            }
        } else {
            rotationAngle = 0.0
        }
    }

    private var statusIconName: String {
        switch status {
        case .success: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .inProgress: return "arrow.triangle.2.circlepath"
        case nil: return "circle"
        }
    }

    private var statusColor: Color {
        switch status {
        case .success: return .syncSuccess
        case .partial: return .syncWarning
        case .failed: return .syncError
        case .inProgress: return .syncProgress
        case nil: return .textTertiary
        }
    }

    // MARK: - Status Text

    @ViewBuilder
    private var statusText: some View {
        if let status {
            switch status {
            case .inProgress:
                Text("Syncing...")
                    .font(.appCaption)
                    .foregroundStyle(Color.syncProgress)
            case .success:
                Text(message ?? "Synced")
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
            case .partial:
                Text(message ?? "Partially synced")
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
            case .failed:
                Text(message ?? "Sync failed")
                    .font(.appCaption)
                    .foregroundStyle(Color.textSecondary)
            }
        } else {
            Text(message ?? "Not synced")
                .font(.appCaption)
                .foregroundStyle(Color.textTertiary)
        }
    }
}

#Preview {
    VStack(spacing: 16) {
        SyncStatusIndicator(status: nil, message: nil)
        SyncStatusIndicator(status: .inProgress, message: nil)
        SyncStatusIndicator(status: .success, message: "All 42 tracks in sync")
        SyncStatusIndicator(status: .partial, message: "4 flagged for review")
        SyncStatusIndicator(status: .failed, message: "3 missing tracks")
    }
    .padding()
    .background(Color.appBackground)
}
