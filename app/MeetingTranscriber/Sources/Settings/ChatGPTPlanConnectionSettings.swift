import SwiftUI

/// Settings controls for connecting Sawti to an eligible ChatGPT plan. The
/// OAuth tokens stay in macOS Keychain and are shared through AppSettings with
/// every Sawti AI feature.
struct ChatGPTPlanConnectionSettings: View {
    @Bindable var settings: AppSettings

    private static let usageSettingsURL = URL(string: "https://chatgpt.com/settings/usage")

    @State private var isConnecting = false
    @State private var isLoadingModels = false
    @State private var isConfirmingSignOut = false
    @State private var availableModels: [ChatGPTPlanModel] = []
    @State private var statusMessage: String?
    @State private var errorMessage: String?

    private var credentials: ChatGPTPlanCredentials? {
        ChatGPTPlanCredentials.decode(settings.chatGPTPlanCredentialJSON)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            accountControls
            modelControls
            Text("Sawti sends AI requests through the official Responses API. This does not give Sawti access to your ChatGPT conversations.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Requests count toward the usage and limits of your ChatGPT plan, shared with other apps. You can review or revoke Sawti’s access in ChatGPT settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let usageSettingsURL = Self.usageSettingsURL {
                Link("Review ChatGPT usage", destination: usageSettingsURL)
                    .font(.caption)
            }
            messageLabels
        }
        .task {
            if credentials != nil {
                await refreshModels()
            }
        }
        .confirmationDialog(
            "Sign out of ChatGPT in Sawti?",
            isPresented: $isConfirmingSignOut,
            titleVisibility: .visible,
        ) {
            Button("Sign Out", role: .destructive) {
                signOut()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Sawti will revoke the renewable sign-in session when possible and remove its local access tokens. Your approved Sawti registration is retained so you can reconnect more easily.")
        }
    }

    @ViewBuilder private var accountControls: some View {
        if let credentials {
            HStack(spacing: 8) {
                Label("Connected to ChatGPT", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                if let email = credentials.email {
                    Text(email)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Reconnect") {
                    connect()
                }
                .disabled(isConnecting)
                Button("Sign Out", role: .destructive) {
                    isConfirmingSignOut = true
                }
                .disabled(isConnecting)
            }
        } else {
            HStack {
                Button {
                    connect()
                } label: {
                    HStack(spacing: 6) {
                        if isConnecting {
                            ProgressView().controlSize(.small)
                        }
                        Text("Continue with ChatGPT")
                    }
                }
                .disabled(isConnecting)
                Spacer()
            }
        }
    }

    @ViewBuilder private var modelControls: some View {
        if !availableModels.isEmpty {
            Picker("Model", selection: $settings.chatGPTPlanModel) {
                ForEach(availableModels) { model in
                    Text(model.displayName).tag(model.slug)
                }
            }
            HStack {
                Button(isLoadingModels ? "Loading Models…" : "Refresh Models") {
                    Task { await refreshModels() }
                }
                .disabled(isLoadingModels || credentials == nil)
                Spacer()
            }
        } else {
            HStack {
                Text("Model")
                Spacer()
                TextField("gpt-6.1-sol", text: $settings.chatGPTPlanModel)
                    .frame(width: 200)
                    .multilineTextAlignment(.trailing)
                Button(isLoadingModels ? "Loading…" : "Load Models") {
                    Task { await refreshModels() }
                }
                .disabled(isLoadingModels || credentials == nil)
            }
        }
    }

    @ViewBuilder private var messageLabels: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
                .textSelection(.enabled)
        }
        if let statusMessage {
            Text(statusMessage)
                .foregroundStyle(.secondary)
                .font(.caption)
                .textSelection(.enabled)
        }
    }

    private func connect() {
        guard !isConnecting else { return }
        isConnecting = true
        errorMessage = nil
        statusMessage = nil
        Task {
            defer { isConnecting = false }
            do {
                let existing: ChatGPTPlanRegistration?
                let idTokenHint: String?
                if let credentials {
                    existing = credentials.registration
                    idTokenHint = credentials.idToken
                } else {
                    existing = await settings.chatGPTPlanCredentialStore.registeredAccount()
                    idTokenHint = nil
                }
                let newCredentials = try await ChatGPTPlanOAuth.authorize(
                    existing: existing,
                    idTokenHint: idTokenHint,
                )
                await settings.chatGPTPlanCredentialStore.replace(with: newCredentials)
                guard !settings.chatGPTPlanCredentialJSON.isEmpty else {
                    throw ChatGPTPlanError.credentialSaveFailed
                }
                settings.protocolProvider = .chatGPTPlan
                statusMessage = "Connected. AI meeting notes and other Sawti AI features can use this account."
                await refreshModels()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor private func refreshModels() async {
        guard credentials != nil else { return }
        isLoadingModels = true
        errorMessage = nil
        defer { isLoadingModels = false }
        do {
            availableModels = try await settings.chatGPTPlanCredentialStore.models()
            if !availableModels.contains(where: { $0.slug == settings.chatGPTPlanModel }),
               let first = availableModels.first {
                settings.chatGPTPlanModel = first.slug
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func signOut() {
        guard let credentials else { return }
        Task {
            let revoked = await ChatGPTPlanOAuth.revoke(credentials)
            settings.chatGPTPlanCredentialJSON = ""
            await settings.chatGPTPlanCredentialStore.clear()
            availableModels.removeAll()
            if settings.protocolProvider == .chatGPTPlan {
                settings.protocolProvider = .none
            }
            statusMessage = revoked
                ? "Signed out of ChatGPT."
                : "Signed out locally. Remote revocation was not confirmed; you can revoke Sawti’s access in ChatGPT settings."
        }
    }
}
