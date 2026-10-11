import AntiphonDesign
import SwiftUI
import UIKit

enum SettingsPage: String, Hashable {
    case spotify, appleMusic, defaults, matching, monitoring, notifications, help
}

/// Settings opens from the avatar on every tab. Accounts come first with
/// their live status, then the four sync defaults, each showing its value.
struct SettingsView: View {
    @State var model: SettingsModel
    @State private var path: [SettingsPage] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(SpotifyAuthManager.self) private var spotifyAuth
    @Environment(SyncCoordinator.self) private var syncCoordinator
    @State private var confirmsReset = false
    @State private var resetError: String?
    @AppStorage(AppAppearance.storageKey) private var appearance: AppAppearance = .system

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "–") (\(info?["CFBundleVersion"] as? String ?? "–"))"
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                header.plainRow()

                Section("Accounts") {
                    NavigationLink(value: SettingsPage.spotify) {
                        row("Spotify", value: model.spotifyStatus, service: .spotify, ok: model.accounts.isSpotifyConnected)
                    }
                    NavigationLink(value: SettingsPage.appleMusic) {
                        row("Apple Music", value: model.appleMusic.storefront ?? model.appleMusic.statusText,
                            service: .appleMusic, ok: model.appleMusic.access == .allowed)
                    }
                }
                .listRowBackground(Color.canvasRaised)

                Section("Syncing") {
                    NavigationLink(value: SettingsPage.defaults) {
                        LabeledContent { Text(SettingsCopy.newSeamDefaults(model.newSeamRemoval)) } label: {
                            Label("New seam defaults", systemImage: "link.badge.plus")
                        }
                    }
                    NavigationLink(value: SettingsPage.matching) {
                        LabeledContent { Text("\(model.threshold)%") } label: { Label("Matching", systemImage: "equal.circle") }
                    }
                    NavigationLink(value: SettingsPage.monitoring) {
                        LabeledContent { Text(model.monitoringValue) } label: { Label("Monitoring", systemImage: "dot.radiowaves.left.and.right") }
                    }
                    NavigationLink(value: SettingsPage.notifications) {
                        LabeledContent { Text(model.notificationsValue) } label: { Label("Notifications", systemImage: "bell") }
                    }
                }
                .listRowBackground(Color.canvasRaised)

                Section {
                    Picker("Theme", selection: $appearance) {
                        ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                } header: {
                    Text("Appearance")
                } footer: {
                    Text("The Home Screen icon follows. iOS briefly confirms each icon change.")
                }

                Section("Antiphon") {
                    if let url = model.exportURL {
                        ShareLink(item: url) { Label("Export sync history", systemImage: "square.and.arrow.up") }
                    }
                    NavigationLink(value: SettingsPage.help) { Label("Help and privacy", systemImage: "hand.raised") }
                    LabeledContent("Version", value: appVersion)
                }
                .listRowBackground(Color.canvasRaised)

                Section {
                    Button("Reset all data", role: .destructive) { confirmsReset = true }
                } footer: {
                    Text("Unlinks every seam, clears history and signs out of Spotify. Your playlists stay exactly as they are on both services.")
                }
                .listRowBackground(Color.canvasRaised)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.thread) }
            }
            .confirmationDialog("Reset all data?", isPresented: $confirmsReset, titleVisibility: .visible) {
                Button("Reset all data", role: .destructive) { Task { await reset() } }
            } message: {
                Text("Every seam is unlinked and history is cleared. Nothing changes in your playlists.")
            }
            .alert("Couldn't reset", isPresented: Binding(get: { resetError != nil }, set: { if !$0 { resetError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(resetError ?? "") }
            .navigationDestination(for: SettingsPage.self) { page in
                switch page {
                case .spotify: SpotifyAccountView(model: model)
                case .appleMusic: AppleMusicAccountView(model: model)
                case .defaults: NewSeamDefaultsView(model: model)
                case .matching: MatchingSettingsView(model: model)
                case .monitoring: MonitoringSettingsView(model: model)
                case .notifications: NotificationSettingsView(model: model)
                case .help: HelpPrivacyView()
                }
            }
            .task { await model.load() }
            #if DEBUG
            .onAppear {
                if let page = DebugRoute.settingsPage.flatMap(SettingsPage.init(rawValue:)), path.isEmpty { path = [page] }
            }
            #endif
        }
        .tint(.thread)
    }

    private var header: some View {
        VStack(spacing: Space.s2) {
            Image("AntiphonIcon")
                .resizable()
                .frame(width: 72, height: 72)
                .clipShape(.rect(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                .accessibilityHidden(true)
            Text(model.name).font(.antiphonTitle2).foregroundStyle(Color.ink)
            Text(model.header).font(.footnote).foregroundStyle(Color.inkMuted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func row(_ title: String, value: String, service: MusicService, ok: Bool) -> some View {
        HStack(spacing: Space.s3) {
            PlatformDot(service: service)
            Text(title).foregroundStyle(Color.ink)
            Spacer()
            Text(value).foregroundStyle(ok ? Color.inkMuted : Color.statusFailed).lineLimit(1)
        }
    }

    private func reset() async {
        await syncCoordinator.cancelAllSyncs()
        spotifyAuth.logout()
        KeychainManager.deleteAll()
        do {
            try await model.resetAll()
        } catch {
            resetError = "Antiphon couldn't clear its data: \(error.localizedDescription)"
        }
    }
}

// MARK: - Accounts

/// Permissions in plain words, including what Antiphon will never do.
/// Disconnecting explains its effect before you tap.
struct SpotifyAccountView: View {
    let model: SettingsModel
    @Environment(SpotifyAuthManager.self) private var spotifyAuth
    @State private var confirmsDisconnect = false

    var body: some View {
        List {
            VStack(spacing: Space.s2) {
                PlatformDot(service: .spotify, size: 28)
                Text(spotifyAuth.userProfile?.displayName ?? (spotifyAuth.isAuthenticated ? "Spotify" : "Not connected"))
                    .font(.antiphonTitle2).foregroundStyle(Color.ink)
                if let line = SettingsCopy.spotifyLine(product: spotifyAuth.userProfile?.product,
                                                       signedInAt: spotifyAuth.isAuthenticated ? model.preferences.spotifySignedInAt : nil) {
                    Text(line).font(.footnote).foregroundStyle(Color.inkMuted)
                }
            }
            .frame(maxWidth: .infinity)
            .plainRow()

            if !spotifyAuth.isAuthenticated {
                SpotifyConnectForm(auth: spotifyAuth)
                    .padding(Space.s4)
                    .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
                    .plainRow()
            }

            Section("Antiphon can") {
                permission("See your playlists", allowed: true)
                permission("Create and edit playlists", allowed: true)
                permission("See your Liked Songs", allowed: true)
                permission("Upload playlist covers", allowed: true)
                permission("Play music, follow, post", allowed: false)
            }
            .listRowBackground(Color.canvasRaised)

            Section("Used in") {
                LabeledContent("Seams", value: "\(model.usage.seams)")
                LabeledContent("Playlists Antiphon made", value: "\(model.usage.madeOnSpotify)")
            }
            .listRowBackground(Color.canvasRaised)

            if spotifyAuth.isAuthenticated {
                Section {
                    Button("Disconnect Spotify", role: .destructive) { confirmsDisconnect = true }
                } footer: {
                    Text(SettingsCopy.disconnectEffect(seams: model.usage.seams))
                }
                .listRowBackground(Color.canvasRaised)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Spotify")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Disconnect Spotify?", isPresented: $confirmsDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) {
                spotifyAuth.logout()
                model.preferences.spotifySignedInAt = nil
            }
        } message: {
            Text(SettingsCopy.disconnectEffect(seams: model.usage.seams))
        }
    }

    private func permission(_ text: String, allowed: Bool) -> some View {
        HStack {
            Image(systemName: allowed ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundStyle(allowed ? Color.statusSynced : Color.inkFaint)
            Text(text).foregroundStyle(Color.ink)
            Spacer()
            if !allowed { Text("Never").foregroundStyle(Color.inkMuted) }
        }
        .accessibilityElement(children: .combine)
    }
}

struct AppleMusicAccountView: View {
    let model: SettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            VStack(spacing: Space.s2) {
                PlatformDot(service: .appleMusic, size: 28)
                Text("Apple Music").font(.antiphonTitle2).foregroundStyle(Color.ink)
                Text([model.appleMusic.statusText, model.appleMusic.storefront].compactMap { $0 }.joined(separator: " · "))
                    .font(.footnote).foregroundStyle(Color.inkMuted)
            }
            .frame(maxWidth: .infinity)
            .plainRow()

            if model.appleMusic.hasSubscription == false {
                Banner(tone: .review, symbol: "exclamationmark.circle.fill", title: "No Apple Music subscription",
                       message: "Antiphon can read your playlists, but adding catalog tracks needs a subscription.")
                    .plainRow()
            }

            Section("Antiphon can") {
                Label("See your library playlists", systemImage: "checkmark.circle.fill")
                Label("Create playlists and add tracks", systemImage: "checkmark.circle.fill")
                Label("Remove and reorder tracks in playlists it created", systemImage: "checkmark.circle.fill")
            }
            .foregroundStyle(Color.ink)
            .listRowBackground(Color.canvasRaised)

            Section("Used in") {
                LabeledContent("Seams", value: "\(model.usage.seams)")
                LabeledContent("Playlists Antiphon made", value: "\(model.usage.madeOnAppleMusic)")
            }
            .listRowBackground(Color.canvasRaised)

            Section {
                Button("Open iOS Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
            } footer: {
                Text("Apple Music access is managed by iOS. Turning it off stops syncing; your playlists stay as they are.")
            }
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Apple Music")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sync defaults

struct NewSeamDefaultsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List {
            Section {
                RemovalChoice(selection: $model.newSeamRemoval).plainRow()
            } footer: {
                Text("Two-way seams ask before removing unless you choose otherwise in a seam's rules.")
            }
            Section {
                Toggle("Keep watching new seams", isOn: $model.newSeamMonitoring).tint(.thread)
            } footer: {
                Text(model.newSeamMonitoring
                     ? "New seams check for changes about every \(RulesCopy.intervalPhrase(model.interval)) when iOS allows."
                     : "New seams only sync when you ask.")
            }
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("New seam defaults")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// "Only add" or "Mirror exactly", as cards with a full sentence each, so
/// the difference is never a guess. Also used in onboarding.
struct RemovalChoice: View {
    @Binding var selection: RemovalPolicy

    var body: some View {
        VStack(spacing: Space.s3) {
            card(.keep, title: "Only add", badge: "Recommended",
                 text: "New tracks get copied. Nothing is ever removed without asking you.")
            card(.mirror, title: "Mirror exactly", badge: nil,
                 text: "Adds and removes, so both playlists stay identical. You can undo any sync from Activity.")
        }
    }

    private func card(_ policy: RemovalPolicy, title: String, badge: String?, text: String) -> some View {
        let isOn = selection == policy || (policy == .keep && selection == .ask)
        return Button { selection = policy } label: {
            HStack(alignment: .top, spacing: Space.s3) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .font(.title3).foregroundStyle(isOn ? Color.thread : Color.inkFaint)
                VStack(alignment: .leading, spacing: Space.s1) {
                    HStack {
                        Text(title).font(.headline).foregroundStyle(Color.ink)
                        if let badge {
                            Text(badge).font(.caption.weight(.semibold)).foregroundStyle(Color.thread)
                                .padding(.horizontal, Space.s2).padding(.vertical, 2)
                                .background(Color.threadSoft, in: .capsule)
                        }
                    }
                    Text(text).font(.subheadline).foregroundStyle(Color.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s4)
            .background(Color.canvasRaised, in: .rect(cornerRadius: Radius.card))
            .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(isOn ? Color.thread : .clear, lineWidth: 2))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The threshold slider is grounded in the person's own history.
struct MatchingSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(MatchingCopy.threshold(model.threshold)).font(.headline).foregroundStyle(Color.ink)
                    Slider(value: Binding(get: { Double(model.threshold) }, set: { model.threshold = Int($0.rounded()) }),
                           in: Double(ConfidencePolicy.reviewFloor + 10)...100, step: 1)
                        .tint(.thread)
                    HStack {
                        Text("Ask about everything")
                        Spacer()
                        Text("Trust Antiphon")
                    }
                    .font(.caption).foregroundStyle(Color.inkMuted)
                    Text(model.wouldAsk).font(.footnote).foregroundStyle(Color.inkMuted)
                }
                .padding(.vertical, Space.s1)
            } footer: {
                Text("Matches at or above this are added without asking. Below \(ConfidencePolicy.reviewFloor)% a track counts as not found.")
            }
            .listRowBackground(Color.canvasRaised)

            Section("When versions differ, prefer") {
                Picker("Explicit or clean", selection: $model.explicit) {
                    ForEach(ExplicitPreference.allCases, id: \.self) { Text(SettingsCopy.explicit($0)).tag($0) }
                }
                Toggle("Original over remaster", isOn: $model.preferOriginal)
                Toggle(isOn: $model.neverLive) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Never use live versions")
                        Text("Unless the source is live").font(.footnote).foregroundStyle(Color.inkMuted)
                    }
                }
                Toggle("Allow radio edits", isOn: $model.allowRadioEdits)
                Picker("Album to match", selection: $model.release) {
                    Text("Same as source").tag(ReleaseChoice.sourceAlbum)
                    Text("Original album").tag(ReleaseChoice.original)
                }
            }
            .tint(.thread)
            .listRowBackground(Color.canvasRaised)

            Section {
                Picker("Check again", selection: $model.recheck) {
                    ForEach(RecheckCadence.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Unavailable tracks")
            } footer: {
                Text("Tracks that weren't found are tried three times, then looked up again on this schedule, because catalogs change.")
            }
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Matching")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct MonitoringSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        List {
            Section {
                ChipBar(RulesCopy.intervals.map { .init($0, RulesCopy.intervalLabel($0)) }, selection: $model.interval)
                    .plainRow()
            } header: {
                Text("Check playlists")
            } footer: {
                Text("For seams that don't set their own. iOS decides the exact moment; Antiphon asks to check about every \(RulesCopy.intervalPhrase(model.interval)).")
            }

            Section {
                Toggle("Removals in the background", isOn: $model.removeInBackground)
            } footer: {
                Text(SettingsCopy.backgroundRemovals(model.removeInBackground))
            }
            .tint(.thread)
            .listRowBackground(Color.canvasRaised)

            Section {
                Toggle("Only on Wi-Fi", isOn: $model.wifiOnly)
                Toggle("Pause in Low Power Mode", isOn: $model.pauseInLowPower)
                Toggle("Quiet hours", isOn: Binding(get: { model.quietHoursOn }, set: { model.quietHoursOn = $0 }))
                if let hours = model.quietHours {
                    DatePicker("From", selection: time(\.startMinute, hours), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: time(\.endMinute, hours), displayedComponents: .hourAndMinute)
                }
            } footer: {
                Text(model.quietHours.map { "No checks or notifications \(SettingsCopy.quietHours($0))." }
                     ?? "Checks run whenever iOS lets Antiphon run.")
            }
            .tint(.thread)
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Monitoring")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func time(_ part: WritableKeyPath<MonitorGates.QuietHours, Int>, _ hours: MonitorGates.QuietHours) -> Binding<Date> {
        Binding {
            Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(hours[keyPath: part]) * 60)
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            var changed = hours
            changed[keyPath: part] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            model.quietHours = changed
        }
    }
}

/// Split by whether you need to act. Routine syncs batch into a summary.
struct NotificationSettingsView: View {
    @Bindable var model: SettingsModel
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if model.notificationStatus == .denied {
                Banner(tone: .review, symbol: "bell.slash.fill", title: "Notifications are off for Antiphon",
                       message: "Turn them on in iOS Settings to hear about anything below.") {
                    Button("Open iOS Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                }
                .plainRow()
            }
            Section {
                toggle("When I need to decide", detail: "Close matches, removals to answer", isOn: $model.notifyDecide)
                toggle("When something breaks", detail: "Sign-ins, deleted playlists, failed syncs", isOn: $model.notifyBreaks)
                Picker("New tracks synced", selection: $model.notifyNewTracks) {
                    ForEach(MonitorNotifications.NewTracks.allCases, id: \.self) { Text(SettingsCopy.newTracks($0)).tag($0) }
                }
                toggle("Weekly digest", detail: "Sundays at 10:00", isOn: $model.weeklyDigest)
            } footer: {
                Text("The daily summary arrives at 19:00 with what monitoring synced so far that day. iOS decides when Antiphon runs, so tracks added late may only show up in the next day's summary.")
            }
            .tint(.thread)
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.footnote).foregroundStyle(Color.inkMuted)
            }
        }
    }
}

struct HelpPrivacyView: View {
    @State private var showsGuide = false

    var body: some View {
        List {
            Section("Privacy") {
                Text("Antiphon runs on this iPhone. It talks to Spotify and Apple Music directly; there's no Antiphon server and no account.")
                Text("Sign-ins stay in the iOS Keychain. Your seams and history stay in Antiphon's storage on this device.")
                Text("Antiphon only reads and edits playlists. It never plays, follows or posts anything.")
            }
            .font(.subheadline).foregroundStyle(Color.ink)
            .listRowBackground(Color.canvasRaised)
            Section("Help") {
                Button("How to get a Spotify client ID") { showsGuide = true }
            }
            .tint(.thread)
            .listRowBackground(Color.canvasRaised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.canvas)
        .navigationTitle("Help and privacy")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showsGuide) { SpotifyKeyGuide() }
    }
}
