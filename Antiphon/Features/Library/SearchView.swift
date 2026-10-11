import AntiphonDesign
import SwiftUI

/// The Search tab. Results answer the question this app exists for: which
/// playlists, on which side, already hold this track.
struct SearchRoot: View {
    let shell: AppShellModel
    @State private var path: [LibraryRoute] = []

    var body: some View {
        @Bindable var model = shell.searchModel
        NavigationStack(path: $path) {
            SearchView(model: model, onOpenSeam: shell.openSeamDetail, onOpenPlaylist: open)
                .navigationTitle("Search")
                .toolbar {
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
        .searchable(text: $model.query, prompt: "Tracks, playlists, artists")
        .onSubmit(of: .search) { model.commit() }
    }

    private func open(_ item: LibraryItem) {
        if let seam = item.seam {
            shell.openSeamDetail(seam.id)
        } else {
            path.append(.playlist(item.playlist))
        }
    }
}

struct SearchView: View {
    let model: SearchModel
    let onOpenSeam: (UUID) -> Void
    let onOpenPlaylist: (LibraryItem) -> Void

    var body: some View {
        @Bindable var model = model
        List {
            Picker("Search in", selection: $model.scope) {
                Text("Tracks").tag(SearchModel.Scope.tracks)
                Text("Playlists").tag(SearchModel.Scope.playlists)
                Text("Artists").tag(SearchModel.Scope.artists)
            }
            .pickerStyle(.segmented)
            .plainRow()

            if model.isEmptyQuery {
                recent
            } else if !model.hasResults {
                Text(noResults).font(.subheadline).foregroundStyle(Color.inkMuted).plainRow()
            } else {
                Section {
                    switch model.scope {
                    case .tracks: ForEach(model.trackHits) { trackRow($0) }
                    case .playlists: ForEach(model.playlistHits) { playlistRow($0) }
                    case .artists: ForEach(model.artistHits) { artistRow($0) }
                    }
                } header: {
                    Text(model.heading)
                }
                .listRowBackground(Color.canvasRaised)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .task { await model.load() }
    }

    private var noResults: String {
        switch model.scope {
        case .tracks, .artists: "Nothing in your seams matches “\(model.query)”. Only playlists in a seam are searched for tracks."
        case .playlists: "No playlist on either side is called anything like “\(model.query)”."
        }
    }

    @ViewBuilder
    private var recent: some View {
        if model.recent.isEmpty {
            ContentUnavailableView("Search your seams", systemImage: "magnifyingglass",
                                   description: Text("Find which playlists, on which side, already hold a track."))
                .plainRow()
        } else {
            Section {
                ScrollView(.horizontal) {
                    HStack(spacing: Space.s2) {
                        ForEach(model.recent, id: \.self) { query in
                            Button(query) { model.use(query) }
                                .glassButton(.secondary)
                        }
                    }
                }
                .scrollIndicators(.hidden)
                .plainRow()
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { model.clearRecent() }.font(.subheadline).tint(.inkMuted)
                }
            }
        }
    }

    /// One recording; under it, where it is on each side. Tapping offers
    /// the seams that hold it.
    private func trackRow(_ hit: TrackHit) -> some View {
        let seams = Array(Set(hit.spotify + hit.appleMusic)).sorted { $0.name < $1.name }
        return Menu {
            ForEach(seams, id: \.id) { seam in
                Button("Open \(seam.name)", systemImage: "link") { onOpenSeam(seam.id) }
            }
        } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                CoverArt(url: hit.artworkURL, seed: hit.title, size: 40)
                VStack(alignment: .leading, spacing: 4) {
                    Text(hit.title).font(.headline).foregroundStyle(Color.ink)
                    Text([hit.artist, hit.album].compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(Color.inkMuted)
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Space.s3) { side(hit, .spotify); side(hit, .appleMusic) }
                        VStack(alignment: .leading, spacing: 2) { side(hit, .spotify); side(hit, .appleMusic) }
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(hit.title), \(hit.artist). Spotify: \(LibrarySearch.sideText(hit.spotify, on: .spotify)). Apple Music: \(LibrarySearch.sideText(hit.appleMusic, on: .appleMusic))")
    }

    private func side(_ hit: TrackHit, _ platform: Platform) -> some View {
        let seams = hit.seams(on: platform)
        return HStack(spacing: Space.s1) {
            PlatformDot(service: SeamPresentation.service(platform), size: 8)
            Text(LibrarySearch.sideText(seams, on: platform))
                .font(.footnote)
                .foregroundStyle(seams.isEmpty ? Color.inkFaint : Color.inkMuted)
        }
    }

    private func playlistRow(_ item: LibraryItem) -> some View {
        Button { onOpenPlaylist(item) } label: {
            HStack(spacing: Space.s3) {
                CoverArt(url: item.playlist.artworkURL, seed: item.playlist.name, size: 48,
                         service: SeamPresentation.service(item.playlist.platform))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.playlist.name).font(.headline).foregroundStyle(Color.ink)
                    Text("\(item.playlist.platform.rawValue) · \(item.detail)").font(.subheadline).foregroundStyle(Color.inkMuted)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.inkFaint)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func artistRow(_ hit: ArtistHit) -> some View {
        Button { model.show(hit) } label: {
            HStack(spacing: Space.s3) {
                Image(systemName: "music.mic").font(.title3).foregroundStyle(Color.inkMuted)
                    .frame(width: 40, height: 40)
                    .background(Color.canvas, in: .circle)
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.name).font(.headline).foregroundStyle(Color.ink)
                    Text("\(PlanCopy.count(hit.trackCount, "track")) · in \(PlanCopy.count(hit.seams.count, "seam"))")
                        .font(.subheadline).foregroundStyle(Color.inkMuted)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}
