import AntiphonDesign
import Observation
import SwiftUI

/// The evidence behind a match and the other versions to choose from.
@MainActor
@Observable
final class MatchDetailModel {
    let item: ReviewItem
    var selected: MatchCandidate?
    var query = ""
    private(set) var searchResults: [MatchCandidate] = []
    private(set) var isSearching = false

    private let search: CatalogSearchService
    private let preferences: AppPreferences

    init(item: ReviewItem, search: CatalogSearchService, preferences: AppPreferences = .shared) {
        self.item = item
        self.search = search
        self.preferences = preferences
        self.selected = item.best
    }

    var rows: [MatchComparison.Row] {
        MatchComparison.rows(source: item.source, candidate: selected?.track ?? item.source)
    }

    var versions: [MatchCandidate] {
        var seen = Set<String>()
        return (item.candidates + searchResults).filter { seen.insert($0.track.id).inserted }
    }

    var preferRemasters: Bool {
        get { preferences.acceptRemasters }
        set { preferences.acceptRemasters = newValue }
    }

    var useTitle: String {
        guard let selected else { return "Use this version" }
        if VersionTag.parse(selected.track.title).tags.contains(.remaster) { return "Use remaster" }
        return "Use this version"
    }

    func runSearch() async {
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let found = (try? await search.search(text, on: item.targetPlatform)) ?? []
        searchResults = found
            .map { track in
                let score = ConfidenceScorer.score(source: item.source, candidate: track, preferences: preferences.versionPreferences)
                return MatchCandidate(track: track, confidence: score.confidence, reason: score.reason)
            }
            .sorted { $0.confidence > $1.confidence }
    }
}

struct MatchDetailView: View {
    @State var model: MatchDetailModel
    /// `nil` skips the track; otherwise the chosen version is added.
    let onDecision: (MatchCandidate?) -> Void
    @State private var showsSearch = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                if dynamicTypeSize.isAccessibilitySize {
                    // Stacked: three columns can't hold words at these sizes.
                    ForEach(model.rows, id: \.label) { row in
                        VStack(alignment: .leading, spacing: Space.s1) {
                            Text(row.label).font(.footnote).foregroundStyle(Color.inkMuted)
                            Text("\(model.item.source.platform.rawValue): \(row.left)").font(row.isCode ? .code : .subheadline)
                            Text("\(model.item.targetPlatform.rawValue): \(row.right)").font(row.isCode ? .code : .subheadline)
                                .foregroundStyle(row.differs ? Color.statusReview : Color.ink)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(row.differs ? "Differs" : "")
                    }
                } else {
                    HStack {
                        Text("").frame(width: 72)
                        platformHeader(model.item.source.platform)
                        platformHeader(model.item.targetPlatform)
                    }
                    ForEach(model.rows, id: \.label) { row in
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.label).font(.footnote).foregroundStyle(Color.inkMuted).frame(width: 72, alignment: .leading)
                            value(row.left, code: row.isCode, highlight: false)
                            value(row.right, code: row.isCode, highlight: row.differs)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityValue(row.differs ? "Differs" : "")
                    }
                }
            }
            .listRowBackground(Color.canvasRaised)

            Section {
                if showsSearch {
                    TextField("Search \(model.item.targetPlatform.rawValue)", text: $model.query)
                        .onSubmit { Task { await model.runSearch() } }
                        .submitLabel(.search)
                }
                ForEach(model.versions, id: \.track.id) { version in
                    Button { model.selected = version } label: {
                        HStack(spacing: Space.s3) {
                            CoverArt(url: version.track.artworkURL.flatMap(URL.init(string:)), seed: version.track.title, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(version.track.title).font(.headline).foregroundStyle(Color.ink)
                                Text([version.track.album, version.track.releaseYear.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                                    .font(.footnote).foregroundStyle(Color.inkMuted)
                            }
                            Spacer()
                            Text("\(version.confidence)%").font(.metricSmall)
                                .foregroundStyle(ConfidenceMeter.band(version.confidence).color)
                            Image(systemName: model.selected?.track.id == version.track.id ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(model.selected?.track.id == version.track.id ? Color.thread : Color.inkFaint)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selected?.track.id == version.track.id ? .isSelected : [])
                }
            } header: {
                HStack {
                    Text("Other versions").font(.antiphonTitle3).foregroundStyle(Color.ink).textCase(nil)
                    Spacer()
                    Button("Search") { showsSearch.toggle() }.font(.subheadline).textCase(nil)
                }
            }
            .listRowBackground(Color.canvasRaised)

            Section {
                MonitorToggle("Prefer remasters", description: "Accept remasters automatically from now on.",
                              isOn: $model.preferRemasters)
            }
            .listRowBackground(Color.canvasRaised)

            if dynamicTypeSize.isAccessibilitySize {
                decisionButtons.plainRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle(model.item.source.title)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // At accessibility sizes the buttons sit at the end of the list instead.
            if !dynamicTypeSize.isAccessibilitySize {
                decisionButtons
                    .padding(.horizontal, Space.s4)
                    .padding(.bottom, Space.s2)
            }
        }
    }

    private var decisionButtons: some View {
        GlassEffectContainer(spacing: Space.s2) {
            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: Space.s2)) : AnyLayout(HStackLayout(spacing: Space.s2))
            layout {
                Button("Skip track") { onDecision(nil) }.buttonSizing(.flexible).glassButton(.secondary)
                Button(model.useTitle) { onDecision(model.selected) }
                    .buttonSizing(.flexible).glassButton(.primary).disabled(model.selected == nil)
            }
        }
    }

    private func platformHeader(_ platform: Platform) -> some View {
        AntiphonDesign.PlatformBadge(service: SeamPresentation.service(platform))
            .font(.footnote)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func value(_ text: String, code: Bool, highlight: Bool) -> some View {
        Text(text)
            .font(code ? .code : .subheadline)
            .foregroundStyle(highlight ? Color.statusReview : Color.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
