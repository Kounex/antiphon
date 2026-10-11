import AntiphonDesign
import SwiftUI

enum LibraryRoute: Hashable {
    case playlist(LibraryPlaylist)
}

/// The Library tab: the grid, and a playlist without a twin.
struct LibraryRoot: View {
    let shell: AppShellModel

    var body: some View {
        @Bindable var shell = shell
        NavigationStack(path: $shell.libraryPath) {
            LibraryView(model: shell.libraryModel, onOpen: open)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { sortMenu }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                    ToolbarItem(placement: .topBarTrailing) {
                        AccountButton(initials: shell.accountInitials) { shell.showsSettings = true }
                    }
                }
                .navigationDestination(for: LibraryRoute.self) { route in
                    switch route {
                    case .playlist(let playlist):
                        PlaylistDetailView(model: shell.makePlaylistDetail(playlist)) { shell.startSeam(from: playlist) }
                    }
                }
        }
    }

    private var sortMenu: some View {
        @Bindable var model = shell.libraryModel
        return Menu("Sort", systemImage: "arrow.up.arrow.down") {
            Picker("Sort", selection: $model.sort) {
                Text("Library order").tag(LibrarySort.library)
                Text("Name").tag(LibrarySort.name)
                Text("Most tracks").tag(LibrarySort.size)
            }
        }
        .tint(.ink)
    }

    /// A playlist in a seam opens the seam; one without a twin opens its page.
    private func open(_ item: LibraryItem) {
        if let seam = item.seam {
            shell.openSeamDetail(seam.id)
        } else {
            shell.libraryPath.append(.playlist(item.playlist))
        }
    }
}

/// Both libraries in one grid, each cover marked with its home platform.
struct LibraryView: View {
    let model: LibraryModel
    let onOpen: (LibraryItem) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var width: CGFloat = 0

    var body: some View {
        @Bindable var model = model
        ScrollView {
            VStack(alignment: .leading, spacing: Space.s4) {
                Picker("Library", selection: $model.scope) {
                    Text("Both").tag(LibraryScope.both)
                    Text("Spotify").tag(LibraryScope.spotify)
                    Text("Apple Music").tag(LibraryScope.appleMusic)
                }
                .pickerStyle(.segmented)

                ChipBar(model.chips, selection: $model.filter)

                ForEach(Platform.allCases.filter { model.scope.includes($0) }, id: \.self) { platform in
                    if let failure = model.failures[platform] {
                        Banner(tone: .failed, symbol: "exclamationmark.triangle.fill",
                               title: "\(platform.rawValue) didn't load", message: failure)
                    }
                }

                if model.isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, Space.s8)
                } else if model.visible.isEmpty {
                    Text(model.emptyMessage)
                        .font(.subheadline).foregroundStyle(Color.inkMuted)
                        .frame(maxWidth: .infinity).padding(.top, Space.s8)
                } else {
                    grid
                }
            }
            .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
            .padding(.horizontal, Space.s4)
            .padding(.bottom, Space.s8)
        }
        .background(Color.canvas)
        .navigationTitle("Library")
        .task { await model.load() }
        .refreshable { await model.load() }
    }

    private var columns: Int { dynamicTypeSize.isAccessibilitySize ? 1 : 2 }

    private var coverSize: CGFloat {
        let spacing = Space.s4 * CGFloat(columns - 1)
        return max(80, (width - spacing) / CGFloat(columns))
    }

    private var grid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: Space.s4, alignment: .top), count: columns),
                  alignment: .leading, spacing: Space.s5) {
            ForEach(model.visible) { item in
                Button { onOpen(item) } label: {
                    LibraryCard(item: item, size: coverSize)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// A cover, its name and where it stands.
struct LibraryCard: View {
    let item: LibraryItem
    let size: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            CoverArt(url: item.playlist.artworkURL, seed: item.playlist.name, size: size,
                     service: SeamPresentation.service(item.playlist.platform))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.playlist.name)
                    .font(.headline).foregroundStyle(Color.ink).lineLimit(2)
                HStack(spacing: Space.s1) {
                    if item.seam != nil {
                        Image(systemName: "link").font(.caption2.weight(.semibold)).foregroundStyle(Color.thread)
                    }
                    Text(item.detail).font(.footnote).foregroundStyle(Color.inkMuted).lineLimit(2)
                }
            }
        }
        .opacity(item.playlist.blockedReason == nil ? 1 : Opacity.missing)
        .contentShape(.rect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.playlist.name), \(item.playlist.platform.rawValue), \(item.detail)")
        .accessibilityAddTraits(.isButton)
    }
}

/// A playlist without a twin. Before you commit, Antiphon checks the other
/// catalog and shows how much of it is there.
struct PlaylistDetailView: View {
    @State var model: PlaylistDetailModel
    let onStitch: () -> Void

    var body: some View {
        List {
            header.plainRow()
            availability.plainRow()
            if let reason = model.playlist.blockedReason {
                Banner(tone: .neutral, symbol: "lock.fill", title: "Antiphon can't use this playlist", message: reason).plainRow()
            } else {
                Button("Stitch to \(model.other.rawValue)", systemImage: "link", action: onStitch)
                    .buttonSizing(.flexible)
                    .glassButton(.primary)
                    .plainRow()
            }
            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity).plainRow()
            } else if let error = model.loadError {
                Banner(tone: .failed, symbol: "exclamationmark.triangle.fill", title: "Couldn't load tracks", message: error).plainRow()
            } else {
                if model.offersNames {
                    Section {
                        Toggle(isOn: Binding(get: { model.showsNames },
                                             set: { on in Task { await model.setShowsNames(on) } })) {
                            HStack(spacing: Space.s2) {
                                Text("Show who added each track").foregroundStyle(Color.ink)
                                if model.isLoadingNames { ProgressView() }
                            }
                        }
                        .tint(.thread)
                        .listRowBackground(Color.canvasRaised)
                    } footer: {
                        Text(model.namesNote)
                    }
                }
                Section {
                    ForEach(Array(model.entries.enumerated()), id: \.offset) { _, entry in
                        AntiphonDesign.TrackRow(
                            title: entry.track.title,
                            detail: model.detail(for: entry),
                            artwork: CoverArt(url: entry.track.artworkURL.flatMap(URL.init(string:)), seed: entry.track.title, size: 40),
                            state: model.isMissing(entry) ? .missing : .plain
                        )
                        .listRowBackground(Color.canvasRaised)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(alignment: .top) { heroBackground }
        .background(Color.canvas)
        .scrollEdgeEffectStyle(.soft, for: .top)
        // Like Apple Music: no title in the bar; the name is in the hero.
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
    }

    private var header: some View {
        VStack(spacing: Space.s3) {
            CoverArt(url: model.playlist.artworkURL, seed: model.playlist.name, size: 200,
                     service: SeamPresentation.service(model.playlist.platform))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
            VStack(spacing: Space.s1) {
                Text(model.playlist.name).font(.antiphonTitle1).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                Text(model.header).font(.footnote).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var availability: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                PlatformDot(service: SeamPresentation.service(model.other))
                Text("Not on \(model.other.rawValue) yet").font(.headline).foregroundStyle(Color.ink)
            }
            if model.report != nil {
                ProgressView(value: model.availableFraction)
                    .tint(.statusSynced)
                    .accessibilityHidden(true)
            }
            Text(model.availabilityText)
                .font(.subheadline).foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            if !model.checksAutomatically, model.report == nil, !model.entries.isEmpty {
                Button("Check \(model.other.rawValue)", systemImage: "magnifyingglass") {
                    Task { await model.checkAvailability() }
                }
                .glassButton(.secondary)
                Text("Spotify has no batch lookup, so this searches once per track.")
                    .font(.footnote).foregroundStyle(Color.inkFaint)
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
    }

    /// The cover's colors bleed under the toolbar and fade into the ground.
    private var heroBackground: some View {
        CoverPlaceholder(seed: model.playlist.name)
            .frame(height: 420)
            .backgroundExtensionEffect()
            .mask(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea(edges: .top)
            .accessibilityHidden(true)
    }
}
