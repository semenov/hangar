import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = Store()
    @State private var showSettings = false
    @State private var showNew = false
    @State private var search = ""
    @State private var toStop: Session?
    @State private var editing: EditTarget?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                Background()
                list
            }
            .navigationBarTitleDisplayMode(.inline) // no title: the limits are the header
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
        .tint(Theme.accentSoft)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showNew) {
            NewProjectView(store: store) { session in
                if let link = session.link { openURL(link) }
            }
        }
        .sheet(item: $editing) { t in
            ProjectEditor(store: store, project: t.project, original: t.description ?? "", running: t.running)
        }
        .confirmationDialog(toStop.map { "Stop \($0.name)?" } ?? "",
                            isPresented: Binding(get: { toStop != nil }, set: { if !$0 { toStop = nil } }),
                            titleVisibility: .visible, presenting: toStop) { s in
            Button("Stop session", role: .destructive) {
                Task { await store.stop(s) }
            }
        } message: { s in
            Text("Anything it is doing is interrupted.")
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
                Section("Running · \(store.sessions.count)") {
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
        return q.isEmpty ? store.idleProjects : store.idleProjects.filter {
            $0.name.lowercased().contains(q) || ($0.description?.lowercased().contains(q) ?? false)
        }
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
                StatusDot(state: store.busy.contains(s.name) ? "starting" : s.state)
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.text)
                    DescriptionLine(text: s.description, describing: store.describing.contains(s.dir))
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
                    ProgressView().frame(width: 36)
                } else {
                    Button { toStop = s } label: {
                        Image(systemName: "stop.fill")
                            .foregroundStyle(Theme.accentSoft.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .listRowBackground(Theme.card)
        .swipeActions {
            Button("Stop", role: .destructive) { toStop = s }
                .tint(Theme.red)
            if !s.dir.isEmpty && !s.dir.hasPrefix("/") {
                Button { editing = EditTarget(project: s.dir, description: s.description, running: true) } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(Theme.accentSoft)
            }
        }
        .contextMenu {
            if let link = s.link {
                Button { openURL(link) } label: { Label("Open in Claude", systemImage: "arrow.up.forward.app") }
                Button { UIPasteboard.general.url = link } label: { Label("Copy link", systemImage: "link") }
            }
            if !s.dir.isEmpty && !s.dir.hasPrefix("/") {
                descriptionMenu(project: s.dir, description: s.description, running: true)
            }
            Button(role: .destructive) { toStop = s } label: {
                Label("Stop session", systemImage: "stop.fill")
            }
        }
    }

    private func projectRow(_ p: Project) -> some View {
        // Tapping the row starts and opens the session; the play button only starts it.
        Button { start(p.name, open: true) } label: {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill")
                    .foregroundStyle(Theme.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    Text(p.name).foregroundStyle(Theme.text)
                    DescriptionLine(text: p.description, describing: store.describing.contains(p.name))
                    HStack(spacing: 6) {
                        Text(p.modified, format: .relative(presentation: .named))
                            .font(.footnote)
                            .foregroundStyle(Theme.secondary)
                        if p.git {
                            Text("git")
                                .font(.caption2.weight(.semibold).monospaced())
                                .foregroundStyle(Theme.accentSoft)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accentSoft.opacity(0.15), in: Capsule())
                        }
                    }
                }
                Spacer()
                if store.busy.contains(p.name) {
                    ProgressView().frame(width: 36)
                } else {
                    Button { start(p.name, open: false) } label: {
                        Image(systemName: "play.fill")
                            .foregroundStyle(Theme.accentSoft.opacity(0.8))
                            .frame(width: 36, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
        .disabled(store.busy.contains(p.name))
        .listRowBackground(Theme.card)
        // Without swipe actions, a horizontal swipe on the row counts as a tap (start and open).
        .swipeActions {
            Button { start(p.name, open: false) } label: { Label("Start", systemImage: "play.fill") }
                .tint(Theme.accent)
            Button { editing = EditTarget(project: p.name, description: p.description, running: false) } label: {
                Label("Edit", systemImage: "pencil")
            }
            .tint(Theme.accentSoft)
        }
        .contextMenu {
            Button { start(p.name, open: true) } label: { Label("Start and open", systemImage: "play.fill") }
            descriptionMenu(project: p.name, description: p.description, running: false)
        }
    }

    @ViewBuilder
    private func descriptionMenu(project: String, description: String?, running: Bool) -> some View {
        Button { editing = EditTarget(project: project, description: description, running: running) } label: {
            Label("Edit…", systemImage: "pencil")
        }
        Button { Task { await store.regenerateDescription(project) } } label: {
            Label("Regenerate with Claude", systemImage: "sparkles")
        }
        .disabled(store.describing.contains(project))
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

struct EditTarget: Identifiable {
    let project: String
    let description: String?
    let running: Bool
    var id: String { project }
}

/// A row's description, or a placeholder while Claude writes one.
struct DescriptionLine: View {
    let text: String?
    let describing: Bool

    var body: some View {
        if describing {
            Label("Claude is writing a description…", systemImage: "sparkles")
                .font(.footnote)
                .foregroundStyle(Theme.accentSoft)
        } else if let text {
            Text(text)
                .font(.footnote)
                .foregroundStyle(Theme.text.opacity(0.75))
                .lineLimit(2)
        }
    }
}

struct StatusDot: View {
    let state: String

    var body: some View {
        let color = state == "ready" ? Theme.green : Theme.amber
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
