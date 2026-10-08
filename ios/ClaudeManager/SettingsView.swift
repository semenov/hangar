import SwiftUI

struct SettingsView: View {
    let store: Store
    @State private var showPair = false
    @State private var showDirect = false
    @State private var toRemove: PairedMac?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(store.macs) { mac in
                        Button { store.select(mac) } label: {
                            HStack {
                                Image(systemName: icon(mac)).foregroundStyle(Theme.accentSoft).frame(width: 24)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name).foregroundStyle(Theme.text)
                                    Text(subtitle(mac)).font(.caption).foregroundStyle(Theme.secondary)
                                }
                                Spacer()
                                if mac.id == store.current?.id {
                                    Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .swipeActions {
                            Button("Remove", role: .destructive) { toRemove = mac }
                        }
                    }
                    Button { showPair = true } label: { Label("Add a Mac", systemImage: "qrcode.viewfinder") }
                } header: {
                    Text("Macs")
                } footer: {
                    Text("On the Mac, `hangar pair` shows a code to scan. Swipe to remove a Mac; it forgets this phone too.")
                }

                Section {
                    Button { showDirect = true } label: { Label("Connect directly…", systemImage: "network") }
                    if !store.macs.contains(where: { $0.kind == .demo }) {
                        Button { store.startDemo() } label: { Label("Try the demo", systemImage: "play.rectangle") }
                    }
                } header: {
                    Text("More")
                } footer: {
                    Text("Direct: an HTTPS address you expose yourself (homebase's private share, Tailscale), without the relay.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() }
            }
            .sheet(isPresented: $showPair) { PairView(store: store) }
            .sheet(isPresented: $showDirect) { DirectView(store: store) }
            .confirmationDialog(toRemove.map { "Remove \($0.name)?" } ?? "",
                                isPresented: Binding(get: { toRemove != nil }, set: { if !$0 { toRemove = nil } }),
                                titleVisibility: .visible, presenting: toRemove) { mac in
                Button("Remove", role: .destructive) { Task { await store.unpair(mac) } }
            } message: { mac in
                Text(mac.kind == .relay ? "The Mac forgets this phone. To use it again, pair it with `hangar pair`." : "")
            }
        }
        .tint(Theme.accentSoft)
        .presentationDetents([.large])
    }

    private func icon(_ mac: PairedMac) -> String {
        switch mac.kind {
        case .relay: "laptopcomputer"
        case .direct: "network"
        case .demo: "play.rectangle"
        }
    }

    private func subtitle(_ mac: PairedMac) -> String {
        switch mac.kind {
        case .relay: "Paired · end-to-end encrypted"
        case .direct: mac.url ?? ""
        case .demo: "Pretend sessions, nothing real"
        }
    }
}

/// Advanced: a server reached over plain HTTPS.
struct DirectView: View {
    let store: Store
    @State private var name = ""
    @State private var url = ""
    @State private var homebaseToken = ""
    @State private var managerToken = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("https://hangar.example.com", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    SecureField("X-Homebase-Token (optional)", text: $homebaseToken)
                        .textInputAutocapitalization(.never).font(.body.monospaced())
                    SecureField("X-Manager-Token", text: $managerToken)
                        .textInputAutocapitalization(.never).font(.body.monospaced())
                } footer: {
                    Text("`hangar serve` with $PORT set listens on 127.0.0.1 and wants the token from ~/Library/Application Support/claude-manager/token.")
                }
            }
            .navigationTitle("Connect directly")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        store.addDirect(name: name, url: url, homebaseToken: homebaseToken, managerToken: managerToken)
                        dismiss()
                    }
                    .bold()
                    .disabled(URL(string: url)?.scheme == nil)
                }
            }
        }
        .tint(Theme.accentSoft)
    }
}
