import SwiftUI

struct SettingsView: View {
    let store: Store
    @State private var remote = ""
    @State private var token = ""
    @State private var managerToken = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(Secrets.publicServer, text: $remote)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    SecureField("X-Homebase-Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    SecureField("X-Manager-Token", text: $managerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                } header: {
                    Text("Server")
                } footer: {
                    Text("The Hangar backend on your Mac, shared with `homebase share --private`. The manager token is in ~/Library/Application Support/claude-manager/token.")
                }
                Section {
                    Button("Reset to defaults") {
                        remote = Secrets.publicServer
                        token = Secrets.homebaseToken
                        managerToken = Secrets.managerToken
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.publicURL = remote
                        store.token = token
                        store.managerToken = managerToken
                        dismiss()
                        Task { await store.refresh() }
                    }
                    .bold()
                }
            }
            .onAppear {
                remote = store.publicURL
                token = store.token
                managerToken = store.managerToken
            }
        }
        .tint(Theme.accentSoft)
        .presentationDetents([.large])
    }
}
