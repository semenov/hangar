import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = Store()
    @State private var showSettings = false
    @State private var showNew = false
    @State private var search = ""
    @State private var toStop: Session?
    @State private var toStart: Project?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Background()
                list
            }
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .searchable(text: $search, prompt: "Projects")
        }
        .tint(Theme.peach)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showNew) {
            NewProjectView(store: store) { session in
                if let link = session.link { openURL(link) }
            }
        }
        .confirmationDialog(toStop.map { $0.server ? "Restart the \($0.name) server?" : "Stop \($0.name)?" } ?? "",
                            isPresented: Binding(get: { toStop != nil }, set: { if !$0 { toStop = nil } }),
                            titleVisibility: .visible, presenting: toStop) { s in
            Button(s.server ? "Restart" : "Stop session", role: .destructive) {
                Task { await store.stop(s) }
            }
        } message: { s in
            Text(s.server
                 ? "Sessions open in it are closed; launchd starts it again within 30 s."
                 : "Anything it is doing is interrupted.")
        }
        .confirmationDialog(toStart.map { "Start a session in \($0.name)?" } ?? "",
                            isPresented: Binding(get: { toStart != nil }, set: { if !$0 { toStart = nil } }),
                            titleVisibility: .visible, presenting: toStart) { p in
            Button("Start and open") { start(p.name, open: true) }
            Button("Start") { start(p.name, open: false) }
        }
        .task(id: scenePhase) {
            // Poll while the app is in the foreground.
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refresh()
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .task(id: scenePhase) {
            // Limits change slowly and are expensive to fetch (claude-monitor caches them for 60 s).
            guard scenePhase == .active else { return }
            while !Task.isCancelled {
                await store.refreshUsage()
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    private var list: some View {
        List {
            if let error = store.error {
                Section { errorRow(error) }
            }
            if store.overview == nil && store.error == nil {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if search.isEmpty {
                Section("Limits") {
                    LimitsCard(usage: store.usage, error: store.usageError)
                        .listRowBackground(Theme.card)
                }
            }
            if search.isEmpty && !store.sessions.isEmpty {
                Section("Running · \(store.sessions.filter { !$0.server }.count)") {
                    ForEach(store.sessions) { s in sessionRow(s) }
                }
            }
            if store.overview != nil {
                Section("Projects") {
                    ForEach(filteredProjects) { p in projectRow(p) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable {
            async let s: Void = store.refresh()
            async let u: Void = store.refreshUsage(force: true)
            _ = await (s, u)
        }
        .animation(.default, value: store.overview)
    }

    private var filteredProjects: [Project] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.idleProjects : store.idleProjects.filter { $0.name.lowercased().contains(q) }
    }

    private func start(_ name: String, open: Bool) {
        Task {
            if let s = await store.start(name), open, let link = s.link {
                openURL(link)
            }
        }
    }

    // MARK: Rows

    private func sessionRow(_ s: Session) -> some View {
        Button {
            if let link = s.link { openURL(link) }
        } label: {
            HStack(spacing: 12) {
                StatusDot(state: store.busy.contains(s.name) ? "starting" : s.state, server: s.server)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.cream)
                    HStack(spacing: 6) {
                        if let sub = s.subtitle { Text(sub) }
                        TimelineView(.periodic(from: .now, by: 30)) { ctx in
                            Text("up " + uptime(since: s.startedAt, now: ctx.date))
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(Theme.secondary)
                    if s.state == "waiting", let w = s.waiting {
                        Text(w)
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.amber)
                            .lineLimit(4)
                    }
                }
                Spacer()
                if store.busy.contains(s.name) {
                    ProgressView()
                }
            }
        }
        .listRowBackground(Theme.card)
        .swipeActions {
            Button(s.server ? "Restart" : "Stop", role: s.server ? nil : .destructive) { toStop = s }
                .tint(s.server ? Theme.amber : Theme.red)
        }
        .contextMenu {
            if let link = s.link {
                Button { openURL(link) } label: { Label("Open in Claude", systemImage: "arrow.up.forward.app") }
                Button { UIPasteboard.general.url = link } label: { Label("Copy link", systemImage: "link") }
            }
            Button(role: .destructive) { toStop = s } label: {
                Label(s.server ? "Restart server" : "Stop session", systemImage: s.server ? "arrow.clockwise" : "stop.fill")
            }
        }
    }

    private func projectRow(_ p: Project) -> some View {
        Button { toStart = p } label: {
            HStack(spacing: 12) {
                Image(systemName: p.git ? "folder.fill.badge.gearshape" : "folder.fill")
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).foregroundStyle(Theme.cream)
                    Text(p.modified, format: .relative(presentation: .named))
                        .font(.footnote)
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                if store.busy.contains(p.name) {
                    ProgressView()
                } else {
                    Image(systemName: "play.fill").foregroundStyle(Theme.peach.opacity(0.8))
                }
            }
        }
        .disabled(store.busy.contains(p.name))
        .listRowBackground(Theme.card)
    }

    private func errorRow(_ error: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Something went wrong", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(Theme.amber)
            Text(error).font(.footnote).foregroundStyle(Theme.secondary)
            Text("Server: \(store.publicURL)").font(.footnote.monospaced()).foregroundStyle(Theme.secondary)
        }
        .listRowBackground(Theme.card)
    }

    private func uptime(since: Date, now: Date) -> String {
        let m = max(0, Int(now.timeIntervalSince(since)) / 60)
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m / (24 * 60))d \(m / 60 % 24)h"
    }
}

struct StatusDot: View {
    let state: String
    let server: Bool

    var body: some View {
        let color = state == "ready" ? (server ? Theme.peach : Theme.green) : Theme.amber
        Circle()
            .fill(color)
            .frame(width: 10, height: 10)
            .shadow(color: color.opacity(0.7), radius: 4)
            .frame(width: 24)
    }
}

#Preview {
    ContentView()
}
