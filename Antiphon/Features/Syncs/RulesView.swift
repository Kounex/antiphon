import AntiphonDesign
import SwiftUI

/// Every rule states its consequence in one line underneath, and that line
/// rewrites itself when the choice changes. Destructive options are opt-in.
struct RulesView: View {
    @State var model: RulesModel
    @Binding var path: [SyncsRoute]
    @State private var confirmUnlink = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        List {
            if let rules = model.rules {
                direction(rules)
                removal(rules)
                order(rules)
                monitoring(rules)
                Section {
                    Button(rules.isPaused ? "Resume this seam" : "Pause this seam") {
                        model.update { $0.isPaused.toggle() }
                    }
                    .foregroundStyle(Color.ink)
                    Button("Unlink playlists", role: .destructive) { confirmUnlink = true }
                        .foregroundStyle(Color.statusFailed)
                } footer: {
                    Text("Unlinking keeps both playlists exactly as they are.")
                }
                .listRowBackground(Color.canvasRaised)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { path.removeLast() }.tint(.thread)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                GlassToast(toast, symbol: model.rules?.isPaused == true ? "pause.fill" : "play.fill")
                    .padding(.bottom, Space.s4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        withAnimation(.smooth) { model.dismissToast() }
                    }
            }
        }
        .animation(.smooth, value: model.toast)
        .confirmationDialog("Unlink these playlists?", isPresented: $confirmUnlink, titleVisibility: .visible) {
            Button("Unlink playlists", role: .destructive) {
                Task {
                    await model.unlink()
                    path.removeAll()
                }
            }
        } message: {
            Text("Both playlists stay exactly as they are. Antiphon stops syncing them.")
        }
        .task { await model.load() }
    }

    private func direction(_ rules: SeamRules) -> some View {
        Section {
            DirectionPicker(
                selection: Binding(get: { model.directionChoice }, set: { model.setDirection($0) }),
                consequence: RulesCopy.direction(rules.direction)
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Space.s2, leading: 0, bottom: Space.s2, trailing: 0))
            if rules.direction != .bidirectional {
                let flow = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s1))
                    : AnyLayout(HStackLayout())
                flow {
                    AntiphonDesign.PlatformBadge(service: rules.direction == .appleToSpotify ? .appleMusic : .spotify)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    Text("copies to").font(.footnote).foregroundStyle(Color.inkMuted)
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    AntiphonDesign.PlatformBadge(service: rules.direction == .appleToSpotify ? .spotify : .appleMusic)
                }
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.canvasRaised)
                Button("Swap direction", systemImage: "arrow.left.arrow.right") { model.swapDirection() }
                    .foregroundStyle(Color.ink)
                    .listRowBackground(Color.canvasRaised)
            }
        } header: {
            Text("Direction")
        } footer: {
            if let note = model.rebuildNote { Text(note) }
        }
    }

    private func removal(_ rules: SeamRules) -> some View {
        Section("When a track is removed") {
            DirectionPicker(
                "When a track is removed",
                options: model.removalOptions,
                selection: Binding(get: { rules.removalPolicy }, set: { policy in model.update { $0.removalPolicy = policy } }),
                consequence: RulesCopy.removal(rules.removalPolicy, direction: rules.direction)
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Space.s2, leading: 0, bottom: Space.s2, trailing: 0))
        }
    }

    private func order(_ rules: SeamRules) -> some View {
        Section("Track order") {
            DirectionPicker(
                "Where new tracks go",
                options: [.init(.sourceOrder, title: "Same place"), .init(.end, title: "At the end")],
                selection: Binding(get: { rules.placement }, set: { placement in model.update { $0.placement = placement } }),
                consequence: RulesCopy.order(rules.placement, direction: rules.direction, appleMusicCanReorder: rules.appleMusicCanReorder)
            )
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: Space.s2, leading: 0, bottom: Space.s2, trailing: 0))
        }
    }

    private func monitoring(_ rules: SeamRules) -> some View {
        let interval = rules.monitorIntervalMinutes ?? AppPreferences.shared.monitorIntervalMinutes
        return Section("Monitoring") {
            MonitorToggle(
                "Watch this seam",
                description: RulesCopy.monitoring(isOn: rules.isMonitored, interval: interval, direction: rules.direction),
                isOn: Binding(get: { rules.isMonitored }, set: { on in model.update { $0.isMonitored = on } })
            )
            Picker("Check every", selection: Binding(
                get: { interval },
                set: { minutes in model.update { $0.monitorIntervalMinutes = minutes; if minutes == 0 { $0.isMonitored = false } } }
            )) {
                ForEach(RulesCopy.intervals + [0], id: \.self) { Text(RulesCopy.intervalLabel($0)).tag($0) }
            }
            .tint(.inkMuted)
            .disabled(!rules.isMonitored)
            Toggle("Notify me about new tracks", isOn: Binding(
                get: { rules.notifyNewTracks }, set: { on in model.update { $0.notifyNewTracks = on } }
            ))
            .tint(.thread)
        }
        .listRowBackground(Color.canvasRaised)
    }
}
