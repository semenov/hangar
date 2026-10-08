import SwiftUI

struct SettingsView: View {
    let store: Store
    @State private var showPair = false
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

                if !store.macs.contains(where: { $0.kind == .demo }) {
                    Section {
                        Button { store.startDemo() } label: { Label("Try the demo", systemImage: "play.rectangle") }
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.bold() }
            }
            .sheet(isPresented: $showPair) { PairView(store: store) }
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
        case .demo: "play.rectangle"
        }
    }

    private func subtitle(_ mac: PairedMac) -> String {
        switch mac.kind {
        case .relay: "Paired · end-to-end encrypted"
        case .demo: "Pretend sessions, nothing real"
        }
    }
}
