import SwiftUI
import WidgetKit

struct SessionsEntry: TimelineEntry {
    let date: Date
    let overview: Overview?
    let usage: Usage?

    /// Running sessions without the "Dev Projects" server.
    var sessions: [Session] { overview?.sessions.filter { !$0.server } ?? [] }
    var sessionLimit: Usage.Limit? { usage?.limits.first { $0.id.contains("session") } ?? usage?.limits.first }
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> SessionsEntry {
        SessionsEntry(date: .now, overview: .sample, usage: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (SessionsEntry) -> Void) {
        if context.isPreview {
            completion(SessionsEntry(date: .now, overview: API.cachedOverview ?? .sample, usage: API.cachedUsage ?? .sample))
            return
        }
        Task { completion(await load()) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<SessionsEntry>) -> Void) {
        Task {
            let entry = await load()
            // Same data, re-rendered every 5 minutes so uptimes and countdowns stay current.
            let entries = (0..<3).map {
                SessionsEntry(date: entry.date.addingTimeInterval(Double($0) * 300), overview: entry.overview, usage: entry.usage)
            }
            completion(Timeline(entries: entries, policy: .after(entry.date.addingTimeInterval(15 * 60))))
        }
    }

    private func load() async -> SessionsEntry {
        async let o = try? API.overview(timeout: 15)
        async let u = try? API.usage(timeout: 15)
        let (overview, usage) = await (o, u)
        return SessionsEntry(date: .now, overview: overview ?? API.cachedOverview, usage: usage ?? API.cachedUsage)
    }
}

extension Overview {
    static let sample = Overview(
        sessions: ["homebase", "game-server", "native-tracker", "censorship"].enumerated().map { i, name in
            Session(name: name, dir: name, pid: i + 1, startedAt: .now.addingTimeInterval(-Double(i + 1) * 4000),
                    url: nil, state: "ready", waiting: nil, managed: true, server: false)
        },
        projects: [])
}

extension Usage {
    static let sample = Usage(
        limits: [
            .init(id: "current-session", label: "Current session", percent: 37,
                  resetsAt: .now.addingTimeInterval(5000), resets: ""),
            .init(id: "current-week-all-models", label: "Current week (all models)", percent: 17,
                  resetsAt: .now.addingTimeInterval(3 * 86400), resets: ""),
        ],
        fetchedAt: .now)
}

// MARK: - Views

struct SessionsWidgetView: View {
    let entry: SessionsEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if entry.overview == nil {
            VStack(spacing: 6) {
                Spark().fill(Theme.coral).frame(width: 22, height: 22)
                Text("No data yet").font(.caption).foregroundStyle(Theme.secondary)
            }
        } else {
            switch family {
            case .systemMedium: MediumView(entry: entry, rows: 4)
            case .systemLarge: LargeView(entry: entry)
            case .accessoryCircular: CircularView(entry: entry)
            case .accessoryRectangular: RectangularView(entry: entry)
            case .accessoryInline: Text("\(entry.sessions.count) sessions running")
            default: SmallView(entry: entry)
            }
        }
    }
}

private func uptime(_ since: Date, _ now: Date) -> String {
    let m = max(0, Int(now.timeIntervalSince(since)) / 60)
    if m < 60 { return "\(m)m" }
    if m < 24 * 60 { return "\(m / 60)h" }
    return "\(m / (24 * 60))d"
}

struct Dot: View {
    let session: Session
    var body: some View {
        Circle()
            .fill(session.state == "ready" ? Theme.green : Theme.amber)
            .frame(width: 7, height: 7)
    }
}

/// Header: spark, count of running sessions.
struct CountHeader: View {
    let entry: SessionsEntry
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(entry.sessions.count)")
                .font(.system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.cream)
            Text(entry.sessions.count == 1 ? "session" : "sessions")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondary)
        }
    }
}

/// Non-animated ring: widgets render a single frame.
struct WidgetRing: View {
    let limit: Usage.Limit
    var lineWidth: CGFloat = 5
    var size: CGFloat = 40

    var body: some View {
        let colors = Theme.gradient(for: limit.percent)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, min(limit.percent, 100) / 100))
                .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int(limit.percent.rounded()))")
                .font(.system(size: size * 0.32, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.cream)
        }
        .frame(width: size, height: size)
    }
}

struct SessionLine: View {
    let session: Session
    let now: Date

    var body: some View {
        let row = HStack(spacing: 7) {
            Dot(session: session)
            Text(session.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(uptime(session.startedAt, now))
                .font(.caption.monospacedDigit())
                .foregroundStyle(Theme.secondary)
        }
        if let link = session.link {
            Link(destination: link) { row }
        } else {
            row
        }
    }
}

struct SmallView: View {
    let entry: SessionsEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Spark().fill(Theme.coral).frame(width: 16, height: 16)
                Spacer()
                if let limit = entry.sessionLimit {
                    WidgetRing(limit: limit, lineWidth: 4, size: 30)
                }
            }
            CountHeader(entry: entry)
            ForEach(entry.sessions.prefix(3)) { s in
                HStack(spacing: 6) {
                    Dot(session: s)
                    Text(s.name).font(.caption).foregroundStyle(Theme.cream.opacity(0.85)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MediumView: View {
    let entry: SessionsEntry
    let rows: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Spark().fill(Theme.coral).frame(width: 18, height: 18)
                CountHeader(entry: entry)
                Spacer(minLength: 0)
                if let limit = entry.sessionLimit {
                    HStack(spacing: 6) {
                        WidgetRing(limit: limit, lineWidth: 4, size: 30)
                        Text("session\nlimit").font(.caption2).foregroundStyle(Theme.secondary)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 9) {
                ForEach(entry.sessions.prefix(rows)) { SessionLine(session: $0, now: entry.date) }
                if entry.sessions.count > rows {
                    Text("+\(entry.sessions.count - rows) more").font(.caption2).foregroundStyle(Theme.secondary)
                }
                if entry.sessions.isEmpty {
                    Text("Nothing running").font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

struct LargeView: View {
    let entry: SessionsEntry
    private let rows = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Spark().fill(Theme.coral).frame(width: 20, height: 20)
                CountHeader(entry: entry)
                Spacer()
                ForEach(entry.usage?.limits.prefix(3) ?? []) { WidgetRing(limit: $0, lineWidth: 4, size: 34) }
            }
            Divider().overlay(Color.white.opacity(0.08))
            ForEach(entry.sessions.prefix(rows)) { SessionLine(session: $0, now: entry.date) }
            if entry.sessions.count > rows {
                Text("+\(entry.sessions.count - rows) more").font(.caption).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct CircularView: View {
    let entry: SessionsEntry
    var body: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: 0) {
                Text("\(entry.sessions.count)").font(.system(size: 22, weight: .bold, design: .rounded))
                Text("RC").font(.system(size: 9, weight: .semibold))
            }
        }
    }
}

struct RectangularView: View {
    let entry: SessionsEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("\(entry.sessions.count) sessions").font(.headline)
            Text(entry.sessions.prefix(3).map(\.name).joined(separator: ", "))
                .font(.caption)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Widget

struct SessionsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SessionsWidget", provider: Provider()) { entry in
            SessionsWidgetView(entry: entry)
                .containerBackground(for: .widget) {
                    LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
                }
        }
        .configurationDisplayName("Claude Sessions")
        .description("Running Remote Control sessions. Tap one to open it in Claude.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct SessionsWidgetBundle: WidgetBundle {
    var body: some Widget { SessionsWidget() }
}

#Preview(as: .systemMedium) {
    SessionsWidget()
} timeline: {
    SessionsEntry(date: .now, overview: .sample, usage: .sample)
}
