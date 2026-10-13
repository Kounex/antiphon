import AntiphonDesign
import SwiftUI

/// First launch: welcome, connect both sides, defaults, twins found.
struct OnboardingView: View {
    @State var model: OnboardingModel
    let onDone: () -> Void
    @Environment(SpotifyAuthManager.self) private var spotifyAuth
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        NavigationStack {
            content.toolbar(model.step == .twins ? .visible : .hidden, for: .navigationBar)
        }
        .tint(.thread)
        .task(id: spotifyAuth.isAuthenticated) { await model.refreshAccounts(spotifyConnected: spotifyAuth.isAuthenticated) }
    }

    private var content: some View {
        ZStack {
            Color.canvas.ignoresSafeArea()
            Group {
                switch model.step {
                case .welcome: WelcomeStep { advance(to: .connect) }
                case .connect: ConnectStep(model: model) { advance(to: .defaults) }
                case .defaults: DefaultsStep(model: model) {
                    Task {
                        await model.saveDefaults()
                        advance(to: .twins)
                    }
                }
                case .twins: TwinsStep(model: model, onDone: onDone)
                }
            }
            // On an iPad this would otherwise stretch a sign-in field across
            // the whole screen; the ZStack centers it once it's capped.
            .frame(maxWidth: 700)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                              removal: .move(edge: .leading).combined(with: .opacity)))
        }
    }

    private func advance(to step: OnboardingModel.Step) {
        withAnimation(.smooth) { model.step = step }
    }
}

/// The thesis in one picture: two stacks, stitched. The thread drifts on
/// load, the only animation on this screen.
private struct WelcomeStep: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: Space.s6) {
            Spacer()
            SeamLine(leading: CoverArt(seed: "Late Night Drive", size: 112, service: .spotify),
                     trailing: CoverArt(seed: "Garden Sundays", size: 112, service: .appleMusic),
                     direction: .twoWay, isMonitoring: true, style: .hero)
                .padding(.horizontal, Space.s5)
            VStack(spacing: Space.s3) {
                Text("Two libraries, one thread.")
                    .font(.antiphonTitle1).foregroundStyle(Color.ink).multilineTextAlignment(.center)
                Text("Antiphon makes your playlists match on Spotify and Apple Music, then keeps watching so they stay that way.")
                    .font(.body).foregroundStyle(Color.inkMuted).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Space.s6)
            Spacer()
            Button("Get started", action: onStart)
                .buttonSizing(.flexible)
                .glassButton(.primary)
                .padding(.horizontal, Space.s5)
                .padding(.bottom, Space.s4)
        }
    }
}

private struct StepHeader: View {
    let step: String?
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let step { Text(step.uppercased()).font(.statusLabel).tracking(TypeMetrics.statusLabelTracking).foregroundStyle(Color.thread) }
            Text(title).font(.antiphonTitle1).foregroundStyle(Color.ink)
            Text(detail).font(.subheadline).foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Spotify signs in through a web sheet with the person's client ID;
/// Apple Music uses the system prompt.
private struct ConnectStep: View {
    let model: OnboardingModel
    let onNext: () -> Void
    @Environment(SpotifyAuthManager.self) private var spotifyAuth

    var body: some View {
        ScrollView {
            VStack(spacing: Space.s5) {
                StepHeader(step: model.stepNumber, title: "Connect both sides",
                           detail: "Antiphon only reads and edits playlists. It never posts, follows or plays anything.")

                serviceCard(.spotify, connected: spotifyAuth.isAuthenticated,
                            summary: model.spotifySummary(name: spotifyAuth.userProfile?.displayName)) {
                    SpotifyConnectForm(auth: spotifyAuth)
                }

                serviceCard(.appleMusic, connected: model.appleMusic.access == .allowed, summary: model.appleSummary) {
                    VStack(alignment: .leading, spacing: Space.s3) {
                        Text(model.appleMusic.access == .denied
                             ? "Apple Music access is off for Antiphon. Turn it on in iOS Settings › Antiphon."
                             : "Adding tracks to your library needs an Apple Music subscription.")
                            .font(.footnote).foregroundStyle(Color.inkMuted)
                        if model.appleMusic.access != .denied {
                            Button("Continue with Apple Music") {
                                Task { await model.connectAppleMusic(spotifyConnected: spotifyAuth.isAuthenticated) }
                            }
                            .buttonSizing(.flexible)
                            .glassButton(.secondary)
                        }
                    }
                }

                Text("Your sign-ins stay in the iOS Keychain. Disconnect any time in Settings.")
                    .font(.footnote).foregroundStyle(Color.inkFaint).multilineTextAlignment(.center)
            }
            .padding(Space.s5)
        }
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: onNext)
                .buttonSizing(.flexible)
                .glassButton(.primary)
                .disabled(!model.canContinueFromConnect(spotifyConnected: spotifyAuth.isAuthenticated))
                .padding(.horizontal, Space.s5)
                .padding(.bottom, Space.s2)
        }
    }

    private func serviceCard(_ service: MusicService, connected: Bool, summary: String,
                             @ViewBuilder connect: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack(spacing: Space.s2) {
                PlatformDot(service: service, size: 12)
                Text(service.name).font(.headline).foregroundStyle(Color.ink)
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.statusSynced)
                }
            }
            if connected {
                if !summary.isEmpty { Text(summary).font(.subheadline).foregroundStyle(Color.inkMuted) }
            } else {
                connect()
            }
        }
        .padding(Space.s4)
        .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
    }
}

/// Safe by default. The two choices are cards with a full sentence each.
private struct DefaultsStep: View {
    @Bindable var model: OnboardingModel
    let onNext: () -> Void

    var body: some View {
        List {
            StepHeader(step: model.stepNumber, title: "How careful should Antiphon be?",
                       detail: "You can change this for each seam later.")
                .plainRow()
            RemovalChoice(selection: $model.removal).plainRow()
            Section {
                Toggle(isOn: $model.keepWatching) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep watching")
                        Text("Checks about every \(RulesCopy.intervalPhrase(AppPreferences.shared.monitorIntervalMinutes)) when iOS allows, even when Antiphon is closed.")
                            .font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                }
                Toggle(isOn: $model.notifyDecide) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tell me when something needs my call")
                        Text("iOS asks for permission next.").font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                }
                Picker("Matching", selection: $model.threshold) {
                    ForEach([80, 85, 90, 95], id: \.self) { Text("Ask me under \($0)%").tag($0) }
                }
            }
            .tint(.thread)
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom) {
            Button("Continue", action: onNext)
                .buttonSizing(.flexible)
                .glassButton(.primary)
                .padding(.horizontal, Space.s5)
                .padding(.bottom, Space.s2)
        }
    }
}

/// The first scan pays off right away: likely pairs are checked by
/// overlap; low-overlap pairs stay unchecked.
private struct TwinsStep: View {
    let model: OnboardingModel
    let onDone: () -> Void

    var body: some View {
        List {
            StepHeader(step: model.stepNumber, title: model.isScanning ? "Looking for twins…" : TwinSuggester.headline(model.suggestions.count),
                       detail: "Same name or mostly the same tracks on both sides. Link them to start syncing.")
                .plainRow()
            if model.isScanning {
                ProgressView().frame(maxWidth: .infinity).plainRow()
            } else if !model.suggestions.isEmpty {
                Section {
                    ForEach(model.suggestions) { suggestion in
                        Button { model.toggle(suggestion) } label: {
                            HStack(spacing: Space.s3) {
                                SeamLine(leading: CoverArt(url: suggestion.pair.spotify.artworkURL, seed: suggestion.pair.spotify.name, size: 40, service: .spotify),
                                         trailing: CoverArt(url: suggestion.pair.appleMusic.artworkURL, seed: suggestion.pair.appleMusic.name, size: 40, service: .appleMusic),
                                         direction: .twoWay, isMonitoring: false, style: .compact)
                                    .frame(width: 112)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(suggestion.title).font(.headline).foregroundStyle(Color.ink)
                                    Text(suggestion.detail).font(.subheadline).foregroundStyle(Color.inkMuted)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: model.checked.contains(suggestion.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.title3)
                                    .foregroundStyle(model.checked.contains(suggestion.id) ? Color.thread : Color.inkFaint)
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(model.checked.contains(suggestion.id) ? .isSelected : [])
                    }
                }
                .listRowBackground(Color.canvasRaised)
            }
            if let rest = model.restLine {
                Text(rest).font(.footnote).foregroundStyle(Color.inkMuted).plainRow()
            }
            if let error = model.linkError {
                Banner(tone: .failed, symbol: "exclamationmark.triangle.fill", title: "Not linked", message: error).plainRow()
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Skip") { model.skip(); onDone() }.tint(.inkMuted)
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: Space.s2) {
                Button(model.isLinking ? "Linking…" : model.linkTitle) {
                    Task { if await model.finish() { onDone() } }
                }
                .buttonSizing(.flexible)
                .glassButton(.primary)
                .disabled(model.isScanning || model.isLinking)
                Text("Nothing changes until you review each seam's first sync.")
                    .font(.footnote).foregroundStyle(Color.inkMuted)
            }
            .padding(.horizontal, Space.s5)
            .padding(.bottom, Space.s2)
        }
        .task { if model.suggestions.isEmpty { await model.scan() } }
    }
}
