import SwiftUI

struct SettingsView: View {
    let store: Store
    @State private var showPair = false
    @State private var toRemove: PairedMac?
    @State private var notTold: PairedMac?
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

                Section {
                    NavigationLink { DiagnosticsView() } label: { Label("Diagnostics", systemImage: "waveform.path.ecg") }
                } footer: {
                    Text("What the connection to the Mac did lately. Useful when something looks off.")
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
                Button("Remove", role: .destructive) {
                    Task { if await !store.unpair(mac) { notTold = mac } }
                }
            } message: { mac in
                Text(mac.kind == .relay ? "The Mac forgets this phone. To use it again, pair it with `hangar pair`." : "")
            }
            .alert("\(notTold?.name ?? "The Mac") couldn't be reached",
                   isPresented: Binding(get: { notTold != nil }, set: { if !$0 { notTold = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It is removed here, but still lists this phone. On the Mac, `hangar devices` shows paired phones and `hangar devices revoke` removes one.")
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

/// The connection log: connects, drops, repeated requests.
struct DiagnosticsView: View {
    @State private var lines = Log.lines
    @State private var copied = false

    var body: some View {
        List {
            if lines.isEmpty {
                Text("Nothing yet.").foregroundStyle(Theme.secondary)
            }
            ForEach(lines.reversed()) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.at, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                    Text(line.text).font(.caption.monospaced()).foregroundStyle(Theme.text)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(copied ? "Copied" : "Copy") {
                    UIPasteboard.general.string = Log.text
                    copied = true
                }
                .disabled(lines.isEmpty)
            }
        }
        .refreshable { lines = Log.lines }
        .task {
            while !Task.isCancelled {
                lines = Log.lines
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}
