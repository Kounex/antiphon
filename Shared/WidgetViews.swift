import AntiphonDesign
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

/// The widgets' views. Compiled into the widget extension and, for
/// screenshots, the app's debug catalog. They read only the snapshot (D4).

/// A cover from downloaded artwork, or the stable placeholder blend.
struct WidgetCover: View {
    let data: Data?
    let seed: String
    let size: CGFloat

    var body: some View {
        Group {
            if let data, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().widgetAccentedRenderingMode(.desaturated).scaledToFill()
            } else {
                CoverPlaceholder(seed: seed)
            }
        }
        .frame(width: size, height: size)
        .clipShape(.rect(cornerRadius: size <= 40 ? Radius.coverSmall : Radius.cover))
        .accessibilityHidden(true)
    }
}

/// A small heading in capitals, like "SEAMS" on board 9.
private struct WidgetEyebrow: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.4)
            .foregroundStyle(Color.ink)
    }
}

/// Medium: seams that need you first, each opening its seam.
struct SeamsWidgetView: View {
    let snapshot: WidgetSnapshot?
    let covers: [UUID: Data]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                WidgetEyebrow(text: "Seams")
                Spacer()
                Text(WidgetCopy.checked(snapshot?.lastCheckedAt, now: now))
                    .font(.caption2)
                    .foregroundStyle(Color.inkMuted)
            }
            if let seams = snapshot?.seams, !seams.isEmpty {
                ForEach(seams.prefix(2)) { seam in
                    Link(destination: WidgetLink.seam(seam.id).url) {
                        HStack(spacing: Space.s3) {
                            WidgetCover(data: covers[seam.id], seed: seam.name, size: 40)
                            Text(seam.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(Color.ink)
                                .lineLimit(1)
                            Spacer(minLength: Space.s2)
                            status(seam.status)
                        }
                    }
                }
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                Text(snapshot == nil ? WidgetCopy.notLoaded : WidgetCopy.noSeams)
                    .font(.footnote)
                    .foregroundStyle(Color.inkMuted)
                Spacer(minLength: 0)
            }
        }
    }

    @ViewBuilder
    private func status(_ status: WidgetSnapshot.Status) -> some View {
        switch status {
        case .review(let n): StatusPill(.review(n))
        case .failed: StatusPill(.failed("Failed"))
        case .paused: StatusPill(.paused)
        case .inSync:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.statusSynced)
                .widgetAccentable()
                .accessibilityLabel("In sync")
        }
    }
}

/// Small: how much is in sync, with Sync all.
struct InSyncWidgetView: View {
    let snapshot: WidgetSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            WidgetEyebrow(text: "In sync")
            Spacer(minLength: 0)
            Text(snapshot.map { WidgetCopy.number($0.tracksInSync) } ?? "–")
                .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.ink)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(snapshot.map { WidgetCopy.tracksAndSeams(seams: $0.seamCount) } ?? WidgetCopy.notLoaded)
                .font(.caption)
                .foregroundStyle(Color.inkMuted)
            Spacer(minLength: 0)
            Button(intent: SyncAllIntent()) {
                Label("Sync all", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.thread)
            .widgetAccentable()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small Home Screen and rectangular Lock Screen: what Antiphon brought in this week.
struct NewThisWeekWidgetView: View {
    let snapshot: WidgetSnapshot?
    let family: WidgetFamily

    var body: some View {
        let text = WidgetCopy.newThisWeek(snapshot?.newThisWeek ?? .init(tracks: 0, playlists: 0))
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Text("New this week").font(.headline).widgetAccentable()
                Text(text).font(.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        default:
            VStack(alignment: .leading, spacing: Space.s2) {
                WidgetCover(data: nil, seed: "new-this-week", size: 48)
                Spacer(minLength: 0)
                Text("New this week")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.ink)
                Text(text)
                    .font(.caption)
                    .foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
