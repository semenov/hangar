import SwiftUI
import UIKit

struct ContentView: View {
    @State private var store = Store()
    @State private var showSettings = false
    @State private var showNew = false
    @State private var search = ""
    @State private var toStop: Session?
    @State private var editing: EditTarget?
    @State private var pairLink: PairLinkItem?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if store.current == nil {
                WelcomeView(store: store)
            } else {
                main
            }
        }
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            if let l = PairLink(url.absoluteString) { pairLink = PairLinkItem(link: l) }
        }
        .sheet(item: $pairLink) { item in PairView(store: store, link: item.link) }
        #if DEBUG
        // Tests: `simctl launch … -pairLink 'hangar://pair?…'` (opening the URL asks for confirmation).
        .onAppear {
            if let s = UserDefaults.standard.string(forKey: "pairLink"), let l = PairLink(s) { pairLink = PairLinkItem(link: l) }
        }
        #endif
    }

    private var main: some View {
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
                if store.macs.count > 1 {
                    ToolbarItem(placement: .principal) {
                        Menu {
                            ForEach(store.macs) { mac in
                                Button { store.select(mac) } label: {
                                    if mac.id == store.current?.id { Label(mac.name, systemImage: "checkmark") } else { Text(mac.name) }
                                }
                            }
                        } label: {
                            HStack(spacing: 4) {
                                Text(store.current?.name ?? "").font(.subheadline.weight(.semibold))
                                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                            }
                            .foregroundStyle(Theme.text)
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showNew = true } label: { Image(systemName: "plus") }
                }
            }
            .searchable(text: $search, prompt: "Projects")
        }
        .tint(Theme.accentSoft)
        .sheet(isPresented: $showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showNew) {
            NewProjectView(store: store) { session in open(session) }
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
        .alert(store.notice?.title ?? "", isPresented: Binding(get: { store.notice != nil }, set: { if !$0 { store.notice = nil } }),
               presenting: store.notice) { n in
            if let s = n.restart {
                Button("Restart") { restart(s) }
                Button("Cancel", role: .cancel) {}
            } else {
                Button("OK", role: .cancel) {}
            }
        } message: { n in
            Text(n.message)
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
            // Limits: once when the app comes to the foreground, and on pull-to-refresh. Each fetch
            // runs `claude -p /usage` on the Mac, so no timer.
            guard scenePhase == .active else { return }
            await store.refreshUsage()
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
            if let s = await store.start(name), open { self.open(s) }
        }
    }

    private func restart(_ session: Session) {
        Task {
            if let s = await store.restart(session) { open(s) }
        }
    }

    /// Opens a session in Claude, or says why it can't be.
    private func open(_ s: Session) {
        switch (s.state, s.link) {
        case ("disconnected", _):
            store.notice = Notice(title: "\(s.name) lost Remote Control", message: s.waiting ?? "", restart: s)
        case ("ready", let link?):
            openURL(link)
        case ("waiting", _):
            store.notice = Notice(title: "\(s.name) is waiting on the Mac",
                                  message: (s.waiting ?? "") + "\n\nRestart it, or answer on the Mac.", restart: s)
        default:
            store.notice = Notice(title: "\(s.name) is still starting",
                                  message: "It opens once Claude Code registers with Remote Control.")
        }
    }

    // MARK: Rows

    private func sessionRow(_ s: Session) -> some View {
        Button {
            open(s)
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
                    if s.state == "waiting" || s.state == "disconnected", let w = s.waiting {
                        Text(w)
                            .font(.caption2.monospaced())
                            .foregroundStyle(s.state == "disconnected" ? Theme.red : Theme.amber)
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
            if !s.dir.isEmpty && !s.dir.hasPrefix("/") && !s.server {
                Button { restart(s) } label: { Label("Restart", systemImage: "arrow.clockwise") }
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
                    if let exit = p.lastExit {
                        Text("Exited \((p.lastExitAt ?? .now).formatted(.relative(presentation: .named))): \(exit)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(Theme.red)
                            .lineLimit(3)
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
        Button {
            Task {
                do { try await store.regenerateDescription(project) } catch {
                    store.notice = Notice(title: "Couldn't describe \((project as NSString).lastPathComponent)",
                                          message: error.localizedDescription)
                }
            }
        } label: {
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
            Text(store.current?.name ?? "").font(.footnote).foregroundStyle(Theme.secondary)
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

struct PairLinkItem: Identifiable {
    let link: PairLink
    var id: String { link.macID }
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
        let color = switch state {
        case "ready": Theme.green
        case "disconnected": Theme.red
        default: Theme.amber
        }
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
