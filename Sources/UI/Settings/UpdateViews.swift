import SwiftUI

/// Appears in the toolbar only when a newer version is waiting.
struct UpdateToolbarButton: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        switch app.updates.state {
        case .available(let v):
            Button { Task { await app.updates.promptInstall() } } label: {
                Label(v == "latest" ? "Update" : "Update to \(v)", systemImage: "arrow.down.circle.fill")
            }
            .tint(.orange)
            .help("A new version of Lumen is ready. It won't install until you confirm.")
        case .installing:
            ProgressView().controlSize(.small).help("Installing update…")
        default:
            EmptyView()
        }
    }
}

struct UpdatesSettingsSection: View {
    @Environment(AppModel.self) private var app
    @AppStorage("autoCheckUpdates") private var autoCheck = true
    @State private var token = Keychain.get(UpdateManager.tokenKey)

    var body: some View {
        Section {
            LabeledContent("Version", value: UpdateManager.currentVersion)
            LabeledContent("Updates from", value: UpdateManager.hasSourceFolder
                           ? "GitHub source (rebuilds here, keeps DeckLink/NDI)" : "GitHub releases — \(UpdateManager.repo)")
            Toggle("Check for updates when Lumen starts", isOn: $autoCheck)
            HStack {
                Button("Check Now") { Task { await app.updates.checkAndPrompt() } }
                    .disabled(app.updates.state == .checking)
                statusText
            }
            SecureField("GitHub token (only if “gh auth login” isn't set up on this Mac)", text: $token)
                .onSubmit { Keychain.set(UpdateManager.tokenKey, token) }
        } header: { Text("Updates") } footer: {
            Text("Lumen's repository is private, so updates need a GitHub login. If the GitHub CLI is signed in on this Mac nothing is needed; otherwise create a fine-grained token with read-only “Contents” access to \(UpdateManager.repo), paste it here, and press Return. Updates never install without your confirmation, and Lumen warns you if something is live.")
        }
        .onDisappear { Keychain.set(UpdateManager.tokenKey, token) }
    }

    @ViewBuilder private var statusText: some View {
        switch app.updates.state {
        case .checking: ProgressView().controlSize(.small)
        case .upToDate: Text("Up to date").foregroundStyle(.secondary).font(.caption)
        case .available(let v): Text(v == "latest" ? "Update available" : "Version \(v) available").foregroundStyle(.orange).font(.caption)
        case .failed(let m): Text(m).foregroundStyle(.red).font(.caption)
        default: EmptyView()
        }
    }
}
