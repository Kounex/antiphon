#if DEBUG
import AntiphonDesign
import SwiftUI

/// Every design-system component in its states, on the real grounds.
/// DEBUG only. Open with `-AntiphonScreen catalog` or `catalog/<Component>`.
struct ComponentCatalogView: View {
    enum Page: String, CaseIterable, Identifiable {
        case tokens = "Tokens"
        case seamLine = "SeamLine"
        case syncCard = "SyncCard"
        case statusPill = "StatusPill"
        case trackRow = "TrackRow"
        case confidenceMeter = "ConfidenceMeter"
        case directionPicker = "DirectionPicker"
        case monitorToggle = "MonitorToggle"
        case glassButton = "GlassButton"
        case platformBadge = "PlatformBadge"
        case syncAccessory = "SyncAccessory"
        case tabBar = "TabBar"
        var id: String { rawValue }
    }

    var initialPage: Page?
    @State private var path: [Page] = []

    var body: some View {
        NavigationStack(path: $path) {
            List(Page.allCases) { page in
                NavigationLink(page.rawValue, value: page)
                    .listRowBackground(Color.canvasRaised)
            }
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Components")
            .navigationDestination(for: Page.self) { page in
                CatalogPage(page: page)
            }
        }
        .tint(.thread)
        .onAppear { if let initialPage { path = [initialPage] } }
    }
}

private struct CatalogPage: View {
    let page: ComponentCatalogView.Page

    var body: some View {
        Group {
            switch page {
            case .trackRow:
                List { TrackRowSamples() }
                    .scrollContentBackground(.hidden)
            case .tabBar:
                TabBarSample()
            default:
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s6) { content }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Space.s4)
                }
            }
        }
        .background(Color.canvas)
        .navigationTitle(page.rawValue)
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .tokens: TokenSamples()
        case .seamLine: SeamLineSamples()
        case .syncCard: SyncCardSamples()
        case .statusPill: StatusPillSamples()
        case .confidenceMeter: ConfidenceSamples()
        case .directionPicker: DirectionSamples()
        case .monitorToggle: MonitorSamples()
        case .glassButton: GlassButtonSamples()
        case .platformBadge: PlatformSamples()
        case .syncAccessory: AccessorySamples()
        case .trackRow, .tabBar: EmptyView()
        }
    }
}

// MARK: - Samples

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.footnote).foregroundStyle(Color.inkMuted).textCase(.uppercase)
    }
}

private struct TokenSamples: View {
    private let colors: [(String, Color)] = [
        ("canvas", .canvas), ("canvas-raised", .canvasRaised), ("canvas-sunken", .canvasSunken),
        ("ink", .ink), ("ink-muted", .inkMuted), ("ink-faint", .inkFaint),
        ("thread", .thread), ("thread-soft", .threadSoft), ("on-thread", .onThread),
        ("status-synced", .statusSynced), ("status-review", .statusReview),
        ("status-failed", .statusFailed), ("status-missing", .statusMissing),
        ("spotify", .spotify), ("applemusic", .appleMusic)
    ]

    var body: some View {
        Caption("Color")
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: Space.s3)], spacing: Space.s3) {
            ForEach(colors, id: \.0) { name, color in
                VStack(alignment: .leading, spacing: Space.s1) {
                    RoundedRectangle(cornerRadius: Radius.cover)
                        .fill(color)
                        .frame(height: 48)
                        .overlay(RoundedRectangle(cornerRadius: Radius.cover).strokeBorder(Color.hairline))
                    Text(name).font(.caption2).foregroundStyle(Color.inkMuted)
                }
            }
        }
        Caption("Type")
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("1,284").metricXL().foregroundStyle(Color.ink)
            Text("Syncs").font(.antiphonLargeTitle)
            Text("Late Night Drive").font(.antiphonTitle1)
            Text("Choose a direction").font(.antiphonTitle2)
            Text("Needs review").font(.antiphonTitle3)
            Text("Running Up That Hill").font(.headline)
            Text("Antiphon checks both playlists every 15 minutes.").font(.body)
            Text("Kate Bush · Hounds of Love").font(.subheadline).foregroundStyle(Color.inkMuted)
            Text("Last checked 4 min ago").font(.footnote).foregroundStyle(Color.inkMuted)
            Text("+12").font(.metric)
            Text("48 / 52").font(.metricSmall)
            Text("GBAYE8500115").font(.code)
        }
        .foregroundStyle(Color.ink)
        Caption("Covers")
        HStack(spacing: Space.s3) {
            ForEach(["Late Night Drive", "Garden Sundays", "Run Club", "Vinyl Rips"], id: \.self) {
                CoverArt(seed: $0, size: 56, service: .spotify)
            }
        }
    }
}

private struct SeamLineSamples: View {
    @State private var direction = SeamDirection.oneWay

    private func covers(_ seed: String, _ size: CGFloat) -> (CoverArt, CoverArt) {
        (CoverArt(seed: seed, size: size, service: .spotify), CoverArt(seed: seed, size: size, service: .appleMusic))
    }

    var body: some View {
        let hero = covers("Late Night Drive", 120)
        Caption("Hero, monitoring, tap to switch direction")
        SeamLine(leading: hero.0, trailing: hero.1, direction: direction, isMonitoring: true, style: .hero)
            .padding(Space.s4)
            .background { CoverPlaceholder(seed: "Late Night Drive").opacity(0.5).clipShape(.rect(cornerRadius: Radius.card)) }
            .onTapGesture { withAnimation(.smooth) { direction = direction == .oneWay ? .twoWay : .oneWay } }
        let card = covers("Garden Sundays", 56)
        Caption("Card, both ways, monitoring")
        SeamLine(leading: card.0, trailing: card.1, direction: .twoWay, isMonitoring: true)
        Caption("Card, not monitoring")
        SeamLine(leading: card.0, trailing: card.1, direction: .oneWay, isMonitoring: false)
        Caption("Card, problem")
        SeamLine(leading: card.0, trailing: card.1, direction: .twoWay, isMonitoring: true, knot: .problem)
        let row = covers("Run Club", 40)
        Caption("Compact")
        SeamLine(leading: row.0, trailing: row.1, direction: .oneWay, isMonitoring: true, style: .compact)
            .frame(width: 120)
    }
}

private struct SyncCardSamples: View {
    var body: some View {
        SyncCard(
            title: "Late Night Drive", subtitle: "Spotify → Apple Music · checked 4 min ago",
            leading: CoverArt(seed: "Late Night Drive", size: 56, service: .spotify),
            trailing: CoverArt(seed: "Late Night Drive", size: 56, service: .appleMusic),
            direction: .oneWay, health: SeamHealth(synced: 48, review: 3, missing: 1, total: 52),
            status: .init(isMonitoring: true)
        )
        SyncCard(
            title: "Garden Sundays", subtitle: "Both ways · 2 added on Spotify today",
            leading: CoverArt(seed: "Garden Sundays", size: 56, service: .appleMusic),
            trailing: CoverArt(seed: "Garden Sundays", size: 56, service: .spotify),
            direction: .twoWay, health: SeamHealth(synced: 117, review: 0, missing: 0, total: 117),
            status: .init(isMonitoring: false)
        )
        SyncCard(
            title: "Vinyl Rips", subtitle: "Apple Music → Spotify · Spotify signed you out",
            leading: CoverArt(seed: "Vinyl Rips", size: 56, service: .appleMusic),
            trailing: CoverArt(seed: "Vinyl Rips", size: 56, service: .spotify),
            direction: .oneWay, health: SeamHealth(synced: 80, review: 0, missing: 7, total: 87),
            status: .init(isMonitoring: true, failure: "Sign in")
        )
    }
}

private struct StatusPillSamples: View {
    var body: some View {
        let states: [StatusPill.State] = [.inSync, .syncing, .monitoring, .review(3), .failed("Failed"), .failed("Sign in"), .missing(.appleMusic), .paused]
        ForEach(states, id: \.self) { StatusPill($0) }
    }
}

private struct TrackRowSamples: View {
    var body: some View {
        let rows: [(String, String, AntiphonDesign.TrackRow.State, Bool)] = [
            ("Nightcall", "Kavinsky · added today", .synced, true),
            ("Midnight City", "M83 · 86% match, remaster", .review(confidence: 86), false),
            ("Titanium", "David Guetta, Sia", .syncing, false),
            ("Running Up That Hill", "Kate Bush · Hounds of Love", .pending, false),
            ("Tokyo Drift (Live Session)", "Not on Apple Music in Germany", .missing, false),
            ("Holocene", "Removed on Apple Music", .removed, false),
            ("Physical", "Apple Music refused the write", .failed, false)
        ]
        ForEach(rows, id: \.0) { title, detail, state, isNew in
            AntiphonDesign.TrackRow(title: title, detail: detail, artwork: CoverArt(seed: title, size: 40), state: state, isNew: isNew)
                .listRowBackground(Color.canvasRaised)
        }
    }
}

private struct ConfidenceSamples: View {
    var body: some View {
        ConfidenceMeter(confidence: 100, reason: "ISRC match", isrc: "FR6V81100040")
        ConfidenceMeter(confidence: 86, reason: "Same artist and title, different release.")
        ConfidenceMeter(confidence: 48, reason: "Title only")
    }
}

private struct DirectionSamples: View {
    @State private var direction = SeamDirection.oneWay
    @State private var keep = true

    var body: some View {
        DirectionPicker(
            selection: $direction,
            consequence: direction == .oneWay
                ? "Tracks added on Spotify are added on Apple Music. Changes made on Apple Music stay there."
                : "Changes on either side are copied to the other. If a track is removed on one side, Antiphon asks first."
        )
        DirectionPicker(
            "When a track is removed",
            options: [.init(true, title: "Keep it"), .init(false, title: "Remove it too")],
            selection: $keep,
            consequence: keep ? "Removing a track on Spotify won't touch Apple Music." : "Removing a track on Spotify removes it on Apple Music too."
        )
    }
}

private struct MonitorSamples: View {
    @State private var on = true
    var body: some View {
        VStack(spacing: 0) {
            MonitorToggle("Watch this seam", description: on ? "About every 15 min. iOS decides the exact moment." : "Antiphon only syncs when you ask.", isOn: $on)
                .padding(.horizontal, Space.s4).padding(.vertical, Space.s2)
        }
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.row))
        GlassToast("Paused. Antiphon won't change Late Night Drive until you turn this back on.", symbol: "pause.fill")
    }
}

private struct GlassButtonSamples: View {
    var body: some View {
        GlassEffectContainer(spacing: Space.s2) {
            VStack(alignment: .leading, spacing: Space.s3) {
                Button("Sync now", systemImage: "arrow.triangle.2.circlepath") {}.glassButton(.primary)
                Button("Link existing", systemImage: "link") {}.glassButton(.secondary)
            }
        }
        ZStack {
            CoverPlaceholder(seed: "Late Night Drive").frame(height: 140).clipShape(.rect(cornerRadius: Radius.card))
            Button("Pause monitoring", systemImage: "pause.fill") {}
                .labelStyle(.iconOnly)
                .glassButton(.overArt)
                .accessibilityLabel("Pause monitoring")
        }
    }
}

private struct PlatformSamples: View {
    var body: some View {
        HStack(spacing: Space.s4) {
            AntiphonDesign.PlatformBadge(service: .spotify)
            AntiphonDesign.PlatformBadge(service: .appleMusic)
        }
        SignInCapsule(service: .spotify, title: "Sign in to Spotify") {}
        SignInCapsule(service: .appleMusic, title: "Continue with Apple Music") {}
        Text("The circle on each capsule is a placeholder for the official badge.")
            .font(.footnote).foregroundStyle(Color.inkMuted)
    }
}

private struct AccessorySamples: View {
    var body: some View {
        SyncAccessory(
            title: "Syncing Run Club", detail: "31 of 52 · Spotify → Apple Music", done: 31, total: 52,
            artwork: CoverArt(seed: "Run Club", size: 32, cornerRadius: 8)
        )
        .frame(height: 56)
        .glassEffect(.regular, in: .capsule)
        Text("In the app this sits in .tabViewBottomAccessory; see TabBar.").font(.footnote).foregroundStyle(Color.inkMuted)
    }
}

private struct TabBarSample: View {
    @State private var tab = AntiphonTab.syncs

    var body: some View {
        TabView(selection: $tab) {
            ForEach([AntiphonTab.syncs, .library, .activity], id: \.self) { item in
                Tab(item.title, systemImage: item.symbol, value: item) {
                    ScrollView {
                        VStack(spacing: Space.s4) {
                            ForEach(0..<12) { i in
                                CoverPlaceholder(seed: "\(item.title)\(i)").frame(height: 80).clipShape(.rect(cornerRadius: Radius.card))
                            }
                        }
                        .padding(Space.s4)
                    }
                    .background(Color.canvas)
                }
                .badge(item == .syncs ? AntiphonTab.syncsBadge(reviewCount: 5) : 0)
            }
            Tab(value: AntiphonTab.search, role: .search) {
                Text("Search").frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.canvas)
            }
        }
        .antiphonTabBar()
        .tabViewBottomAccessory {
            SyncAccessory(
                title: "Syncing Run Club", detail: "31 of 52 · Spotify → Apple Music", done: 31, total: 52,
                artwork: CoverArt(seed: "Run Club", size: 32, cornerRadius: 8)
            )
        }
    }
}
#endif
