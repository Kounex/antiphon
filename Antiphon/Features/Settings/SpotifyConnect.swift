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

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            HStack {
                Text("Your Spotify client ID").font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
                Spacer()
                Button("How to get one") { showsGuide = true }.font(.subheadline).tint(.thread)
            }
            TextField("Paste your client ID", text: $clientId)
                .font(.body.monospaced())
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isFocused)
                .padding(Space.s3)
                .background(Color.canvas, in: .rect(cornerRadius: Radius.coverSmall + 4))
                .onSubmit(save)
            Text("Spotify only lets apps sign in with a client ID you create. It stays in this iPhone's Keychain.")
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
            .disabled(clientId.trimmingCharacters(in: .whitespaces).count < 20 || isConnecting)
            if let error = auth.authError {
                Text(error).font(.footnote).foregroundStyle(Color.statusFailed)
            }
        }
        .onAppear { clientId = auth.clientId ?? "" }
        .sheet(isPresented: $showsGuide) { SpotifyKeyGuide() }
    }

    private func save() {
        let trimmed = clientId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return }
        auth.clientId = trimmed
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

/// How to create a Spotify client ID, step by step.
struct SpotifyKeyGuide: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
        var code: String? = nil
        var link: URL? = nil
    }

    private let steps = [
        Step(id: 1, title: "Open the Spotify developer dashboard",
             detail: "Sign in with your Spotify account.", link: URL(string: "https://developer.spotify.com/dashboard")),
        Step(id: 2, title: "Create an app", detail: "Any name and description work, for example “Antiphon”."),
        Step(id: 3, title: "Add the redirect URI", detail: "In the app's settings, add exactly:", code: AppConstants.Spotify.redirectURI),
        Step(id: 4, title: "Choose Web API", detail: "Under the APIs the app uses, select Web API."),
        Step(id: 5, title: "Copy the client ID", detail: "It's on the app's overview page. Paste it into Antiphon.")
    ]

    var body: some View {
        NavigationStack {
            List {
                Text("Antiphon talks to Spotify directly with a client ID you create. There's no Antiphon server in between.")
                    .font(.subheadline).foregroundStyle(Color.inkMuted).plainRow()
                Section {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: Space.s3) {
                            Text("\(step.id)")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Color.thread)
                                .frame(width: 28, height: 28)
                                .background(Color.threadSoft, in: .circle)
                            VStack(alignment: .leading, spacing: Space.s1) {
                                Text(step.title).font(.headline).foregroundStyle(Color.ink)
                                Text(step.detail).font(.subheadline).foregroundStyle(Color.inkMuted)
                                if let code = step.code {
                                    Text(code).font(.callout.monospaced()).textSelection(.enabled)
                                        .padding(Space.s2).background(Color.canvas, in: .rect(cornerRadius: 8))
                                }
                                if let link = step.link {
                                    Link("developer.spotify.com", destination: link).font(.subheadline).tint(.thread)
                                }
                            }
                        }
                        .padding(.vertical, Space.s1)
                    }
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
}
