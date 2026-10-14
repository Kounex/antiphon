import AntiphonDesign
import SwiftUI
import UIKit

/// Spotify sign-in with the person's own client ID (BYOK). Used in
/// onboarding and on the Spotify account page.
struct SpotifyConnectForm: View {
    @Bindable var auth: SpotifyAuthManager
    var preferences: AppPreferences = .shared

    @State private var clientId = ""
    @State private var isConnecting = false
    @State private var showsGuide = false
    @FocusState private var isFocused: Bool

    private var check: SpotifyClientID.Check { SpotifyClientID.check(clientId) }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Your Spotify client ID").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Spacer()
                Button("How to get one") { showsGuide = true }.font(.subheadline).tint(.thread)
            }
            HStack(spacing: Space.s2) {
                TextField("Paste your client ID", text: $clientId)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .padding(Space.s3)
                    .background(Color.canvas, in: .rect(cornerRadius: Radius.coverSmall + 4))
                    .onSubmit(save)
                // the system Paste button: no "Allow Paste" prompt
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in
                        clientId = strings.first ?? ""
                        isFocused = false
                        save()
                    }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.capsule)
                .tint(.thread)
            }
            if check == .invalid && !isFocused {
                Text(SpotifyClientID.invalidMessage)
                    .font(.footnote).foregroundStyle(Color.statusFailed)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Needs Spotify Premium: Spotify only runs the apps you create for Premium accounts. Your client ID stays in this iPhone's Keychain.")
                .font(.footnote).foregroundStyle(Color.inkMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                save()
                Task { await connect() }
            } label: {
                Label(isConnecting ? "Connecting…" : "Connect Spotify", systemImage: "person.crop.circle.badge.checkmark")
            }
            .buttonSizing(.flexible)
            .glassButton(.primary)
            .disabled(!isValid || isConnecting)
            if let error = auth.authError {
                Text(error).font(.footnote).foregroundStyle(Color.statusFailed)
            }
        }
        .onAppear { clientId = auth.clientId ?? "" }
        .sheet(isPresented: $showsGuide) { SpotifyKeyGuide() }
    }

    private var isValid: Bool {
        if case .valid = check { true } else { false }
    }

    private func save() {
        guard case .valid(let id) = check else { return }
        clientId = id
        auth.clientId = id
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })?
            .windows.first(where: \.isKeyWindow) else {
            auth.authError = "Antiphon couldn't show the Spotify sign-in. Try again."
            return
        }
        do {
            try await auth.startLogin(presentingFrom: window)
            preferences.spotifySignedInAt = Date()
        } catch {
            auth.authError = error.localizedDescription
        }
    }
}

/// How to create a Spotify client ID, step by step, in the order of
/// Spotify's "Create app" form; every value to type has a Copy button.
struct SpotifyKeyGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text("Antiphon talks to Spotify directly, as an app you create. There's no Antiphon server in between.")
                        .font(.subheadline).foregroundStyle(Color.inkMuted)
                    Label {
                        Text("You need Spotify Premium. Since February 2026 Spotify only runs the apps you create for Premium accounts. It takes about two minutes.")
                    } icon: {
                        Image(systemName: "info.circle.fill").foregroundStyle(Color.thread)
                    }
                    .font(.subheadline).foregroundStyle(Color.ink)
                    .padding(Space.s3)
                    .background(Color.threadSoft, in: .rect(cornerRadius: 12))
                }
                .plainRow()
                Section {
                    step(1, "Open the Spotify developer dashboard",
                         "Sign in with your Spotify account. Accept the developer terms if Spotify asks.") {
                        Link(destination: URL(string: "https://developer.spotify.com/dashboard")!) {
                            Label("Open the dashboard", systemImage: "arrow.up.forward.app")
                        }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.thread)
                    }
                    step(2, "Tap Create app and fill in the form",
                         "Copy each value into its field. Leave Website empty.") {
                        CopyRow(label: "App name", value: "Antiphon")
                        CopyRow(label: "App description", value: "Playlist sync")
                        CopyRow(label: "Redirect URI, then tap Add", value: AppConstants.Spotify.redirectURI)
                        Text("Tick **Web API**, accept the terms and tap **Save**.")
                            .font(.subheadline).foregroundStyle(Color.ink)
                    }
                    step(3, "Copy the Client ID",
                         "It's at the top of your new app's page. Antiphon doesn't need the client secret.") { EmptyView() }
                    step(4, "Paste it into Antiphon",
                         "Come back and tap the Paste button next to the client ID field, then Connect Spotify.") { EmptyView() }
                }
                .listRowBackground(Color.canvasRaised)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color.canvas)
            .navigationTitle("Spotify client ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.tint(.thread) }
            }
        }
    }

    private func step(_ number: Int, _ title: String, _ detail: String,
                      @ViewBuilder extra: () -> some View) -> some View {
        HStack(alignment: .top, spacing: Space.s3) {
            Text("\(number)")
                .font(.subheadline.weight(.bold)).foregroundStyle(Color.thread)
                .frame(width: 28, height: 28)
                .background(Color.threadSoft, in: .circle)
            VStack(alignment: .leading, spacing: Space.s2) {
                Text(title).font(.headline).foregroundStyle(Color.ink)
                Text(detail).font(.subheadline).foregroundStyle(Color.inkMuted)
                extra()
            }
        }
        .padding(.vertical, Space.s1)
    }
}

/// A value to type into Spotify's form, with a Copy button.
private struct CopyRow: View {
    let label: String
    let value: String
    @State private var copied = false
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s1) {
            Text(label).font(.caption.weight(.semibold)).foregroundStyle(Color.inkMuted)
            // the button goes under the value at accessibility sizes
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s2))
                : AnyLayout(HStackLayout(spacing: Space.s2))
            layout {
                Text(value).font(.callout.monospaced()).foregroundStyle(Color.ink)
                    .lineLimit(2).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = value
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.thread)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(copied ? "Copied \(label)" : "Copy \(label)")
            }
            .padding(Space.s2)
            .background(Color.canvas, in: .rect(cornerRadius: 8))
        }
        .sensoryFeedback(.success, trigger: copied) { _, new in new }
        .task(id: copied) {
            guard copied else { return }
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}
