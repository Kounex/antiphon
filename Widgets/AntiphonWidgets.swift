import AntiphonDesign
import SwiftUI
import WidgetKit

struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
    let covers: [UUID: Data]
}

/// Reads the app's snapshot from the App Group (D4). Entries every five
/// minutes keep "checked 2 min ago" right until the app writes a new one.
struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: Date(), snapshot: .sample, covers: [:])
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : current(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let now = Date()
        let first = current(at: now)
        let entries = (0..<12).map { step in
            SnapshotEntry(date: now.addingTimeInterval(Double(step) * 300), snapshot: first.snapshot, covers: first.covers)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private func current(at date: Date) -> SnapshotEntry {
        guard let folder = AppGroup.containerURL, let snapshot = WidgetSnapshot.read(from: folder) else {
            return SnapshotEntry(date: date, snapshot: nil, covers: [:])
        }
        return SnapshotEntry(date: date, snapshot: snapshot, covers: snapshot.covers(in: folder))
    }
}

struct SeamsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Seams", provider: SnapshotProvider()) { entry in
            SeamsWidgetView(snapshot: entry.snapshot, covers: entry.covers, now: entry.date)
                .containerBackground(Color.canvasRaised, for: .widget)
        }
        .configurationDisplayName("Seams")
        .description("Seams that need you first, and when they were checked.")
        .supportedFamilies([.systemMedium])
    }
}

struct InSyncWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "InSync", provider: SnapshotProvider()) { entry in
            InSyncWidgetView(snapshot: entry.snapshot)
                .containerBackground(Color.canvasRaised, for: .widget)
        }
        .configurationDisplayName("In sync")
        .description("How many tracks are in sync. Sync all syncs every seam now, without a preview; close matches wait in Review, and a new seam's first sync happens in Antiphon.")
        .supportedFamilies([.systemSmall])
    }
}

struct NewThisWeekWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NewThisWeek", provider: SnapshotProvider()) { entry in
            NewThisWeekEntryView(entry: entry)
        }
        .configurationDisplayName("New this week")
        .description("Tracks Antiphon brought in over the last seven days.")
        .supportedFamilies([.systemSmall, .accessoryRectangular])
    }
}

private struct NewThisWeekEntryView: View {
    let entry: SnapshotEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        NewThisWeekWidgetView(snapshot: entry.snapshot, family: family)
            .containerBackground(for: .widget) {
                if family == .accessoryRectangular { Color.clear } else { Color.canvasRaised }
            }
            .widgetURL(WidgetLink.newTracks.url)
    }
}

@main
struct AntiphonWidgets: WidgetBundle {
    var body: some Widget {
        SeamsWidget()
        InSyncWidget()
        NewThisWeekWidget()
        SyncActivityWidget()
    }
}
