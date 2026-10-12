import ActivityKit
import AntiphonDesign
import SwiftUI
import UIKit
import WidgetKit

/// The Live Activity for a sync longer than 20 seconds (9.01), started in the
/// app or from Sync all. Background runs can't start one (iOS).
struct SyncActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var seamName: String
        /// "Adding to Apple Music", "Checking tracks", or how it ended.
        var phase: String
        var done: Int
        var total: Int
        /// Cover files in the App Group (`WidgetSnapshot.coverFile`), if saved.
        var sourceCover: String? = nil
        var targetCover: String? = nil
        var finished = false
        /// Finished without getting through: "Stopped" rather than "Done".
        var failed = false
        /// "Spotify → Apple Music"
        var direction: String? = nil
        /// "about 2 min left", once it can be told.
        var timeLeft: String? = nil

        /// Under the bar: direction, and time left.
        var detail: String? {
            let parts = [direction, timeLeft].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

/// When the Live Activity starts and how often it changes.
enum SyncActivityPolicy {
    static let startAfter: TimeInterval = 20
    static let minimumUpdateInterval: TimeInterval = 2
    /// How long the result stays in the Dynamic Island before the activity
    /// ends; an ended activity only stays on the Lock Screen.
    static let resultShownFor: TimeInterval = 4
    /// Updates come every few seconds while the sync runs. When none has come
    /// for this long, iOS has paused the app (it left the screen): the activity
    /// says so instead of a bar that looks like it's still moving.
    static let staleAfter: TimeInterval = 30
    static let pausedText = "Paused · open Antiphon to finish"

    static func staleDate(now: Date) -> Date { now.addingTimeInterval(staleAfter) }

    static func shouldStart(startedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(startedAt) >= startAfter
    }

    /// ActivityKit limits updates: counts at most every 2 seconds, a new
    /// phase or seam at once, nothing when nothing changed.
    static func shouldUpdate(from old: SyncActivityAttributes.ContentState, to new: SyncActivityAttributes.ContentState,
                             lastUpdate: Date, now: Date) -> Bool {
        guard old != new else { return false }
        if old.phase != new.phase || old.seamName != new.seamName || new.finished { return true }
        return now.timeIntervalSince(lastUpdate) >= minimumUpdateInterval
    }
}

// MARK: - Views

/// Two covers stitched with the gold thread, as on the sync cards.
private struct StitchedCovers: View {
    let state: SyncActivityAttributes.ContentState
    let size: CGFloat
    var paused = false

    var body: some View {
        let source = Self.data(state.sourceCover), target = Self.data(state.targetCover)
        if source == nil && target == nil {
            // No real artwork (Sync all, or playlists without covers): a
            // symbol, not two blends that would read as album covers.
            ActivityStatusIcon(state: state, paused: paused)
                .font(.system(size: size * 0.45))
                .frame(width: size, height: size)
                .background(Color.canvasSunken, in: .rect(cornerRadius: size <= 40 ? Radius.coverSmall : Radius.cover))
        } else {
            HStack(spacing: 0) {
                cover(source)
                Rectangle().fill(Color.thread).frame(width: size * 0.25, height: 2)
                cover(target)
            }
        }
    }

    /// A side without artwork (a new playlist) gets a plain tile, not a
    /// blend that would read as an album cover.
    @ViewBuilder
    private func cover(_ data: Data?) -> some View {
        if let data {
            WidgetCover(data: data, seed: state.seamName, size: size)
        } else {
            Image(systemName: "music.note")
                .font(.system(size: size * 0.4))
                .foregroundStyle(Color.inkMuted)
                .frame(width: size, height: size)
                .background(Color.canvasSunken, in: .rect(cornerRadius: size <= 40 ? Radius.coverSmall : Radius.cover))
        }
    }

    fileprivate static func data(_ file: String?) -> Data? {
        guard let file, let folder = AppGroup.containerURL else { return nil }
        return try? Data(contentsOf: folder.appending(path: WidgetSnapshot.coversFolder).appending(path: file))
    }
}

/// The compact island's leading side: the seam's cover while syncing (a
/// placeholder blend would read as an album cover, so a sync symbol when
/// there's none), a checkmark when done, a warning when stopped.
private struct ActivityStatusIcon: View {
    let state: SyncActivityAttributes.ContentState
    var paused = false

    var body: some View {
        if paused && !state.finished {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Color.inkMuted)
                .accessibilityLabel("Paused")
        } else if state.failed {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.statusFailed)
                .accessibilityLabel("Stopped")
        } else if state.finished {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.thread)
                .accessibilityLabel("Done")
        } else if let cover = StitchedCovers.data(state.sourceCover) {
            WidgetCover(data: cover, seed: state.seamName, size: 20)
        } else {
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundStyle(Color.thread)
                .accessibilityLabel("Syncing")
        }
    }
}

private struct ActivityProgress: View {
    let state: SyncActivityAttributes.ContentState

    var body: some View {
        ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
            .tint(Color.thread)
    }
}

/// The Lock Screen banner (board 9): covers, the seam and what's happening,
/// the count, the bar, then direction and time left.
struct SyncActivityLockScreenView: View {
    let state: SyncActivityAttributes.ContentState
    /// No update for a while: iOS paused the app.
    var isStale = false

    private var paused: Bool { isStale && !state.finished }

    var body: some View {
        VStack(spacing: Space.s3) {
            HStack(spacing: Space.s3) {
                StitchedCovers(state: state, size: 40, paused: paused)
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.seamName).font(.headline).lineLimit(1).minimumScaleFactor(0.85)
                    Text(paused ? SyncActivityPolicy.pausedText : state.phase)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if !state.finished {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text("\(state.done)").font(.system(.title2, design: .rounded, weight: .semibold).monospacedDigit())
                        Text("of \(state.total)").font(.caption).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                }
            }
            if !state.finished {
                ActivityProgress(state: state).opacity(paused ? 0.4 : 1)
            }
            if let detail = state.detail, !paused {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(Space.s4)
    }
}

struct SyncActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SyncActivityAttributes.self) { context in
            SyncActivityLockScreenView(state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Color.canvasRaised.opacity(0.85))
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                // The expanded island's top corners are tightly rounded: keep
                // content clear of them.
                DynamicIslandExpandedRegion(.leading) {
                    StitchedCovers(state: state, size: 32)
                        .padding(.leading, Space.s3)
                        .padding(.top, Space.s2)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if state.finished {
                            ActivityStatusIcon(state: state).font(.title3)
                        } else {
                            Text("\(state.done) of \(state.total)").font(.caption.monospacedDigit())
                        }
                    }
                    .padding(.trailing, Space.s3)
                    .padding(.top, Space.s2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text(state.seamName).font(.headline).lineLimit(1)
                        Text(context.isStale && !state.finished ? SyncActivityPolicy.pausedText : state.phase)
                            .font(.footnote).foregroundStyle(.secondary)
                        if !state.finished { ActivityProgress(state: state) }
                    }
                    // The region centres its content; the text lines up with the covers.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.s3)
                    .padding(.bottom, Space.s2)
                }
            } compactLeading: {
                ActivityStatusIcon(state: state, paused: context.isStale)
            } compactTrailing: {
                Text(state.failed ? "Stopped" : state.finished ? "Done" : "\(state.done)/\(state.total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.thread)
            } minimal: {
                ProgressView(value: Double(state.done), total: Double(max(state.total, 1)))
                    .progressViewStyle(.circular)
                    .tint(Color.thread)
            }
            .keylineTint(Color.thread)
        }
    }
}
