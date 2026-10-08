import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let usage: Usage?
}

struct Provider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: .now, usage: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping @Sendable (UsageEntry) -> Void) {
        if context.isPreview {
            completion(UsageEntry(date: .now, usage: API.cachedUsage ?? .sample))
            return
        }
        Task { completion(UsageEntry(date: .now, usage: await load())) }
    }

    func getTimeline(in context: Context, completion: @escaping @Sendable (Timeline<UsageEntry>) -> Void) {
        Task {
            let usage = await load()
            // Same data, re-rendered every 5 minutes so the reset countdowns stay current.
            let now = Date.now
            let entries = (0..<6).map { UsageEntry(date: now.addingTimeInterval(Double($0) * 300), usage: usage) }
            completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(15 * 60))))
        }
    }

    private func load() async -> Usage? {
        (try? await API.usage(timeout: 20)) ?? API.cachedUsage
    }
}

extension Usage {
    static let sample = Usage(
        limits: [
            .init(id: "current-session", label: "Current session", percent: 42,
                  resetsAt: .now.addingTimeInterval(3 * 3600), resets: ""),
            .init(id: "current-week-all-models", label: "Current week (all models)", percent: 18,
                  resetsAt: .now.addingTimeInterval(3 * 86400), resets: ""),
        ],
        fetchedAt: .now)
}

// MARK: - Views

struct UsageWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let usage = entry.usage, let session = usage.session {
            switch family {
            case .systemMedium: MediumView(usage: usage, session: session, now: entry.date)
            case .accessoryCircular: CircularView(session: session)
            case .accessoryRectangular: RectangularView(usage: usage, session: session, now: entry.date)
            case .accessoryInline: InlineView(usage: usage, session: session)
            default: SmallView(usage: usage, session: session, now: entry.date)
            }
        } else {
            VStack(spacing: 6) {
                HangarMark().fill(Theme.accent).frame(width: 22, height: 22)
                Text("No data yet").font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }
}

/// Non-animated ring: widgets render a single frame, so no onAppear animations.
struct WidgetRing<Label: View>: View {
    let percent: Double
    let lineWidth: CGFloat
    @ViewBuilder var label: Label

    var body: some View {
        let colors = Theme.gradient(for: percent)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.005, min(percent, 100) / 100))
                .stroke(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            label
        }
    }
}

struct WidgetBar: View {
    let percent: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: Theme.gradient(for: percent), startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(6, geo.size.width * min(percent, 100) / 100))
            }
        }
        .frame(height: 6)
    }
}

private func pct(_ p: Double) -> String { "\(Int(p.rounded()))%" }

struct SmallView: View {
    let usage: Usage
    let session: Usage.Limit
    let now: Date

    var body: some View {
        VStack(spacing: 8) {
            WidgetRing(percent: session.percent, lineWidth: 10) {
                VStack(spacing: 1) {
                    Text(pct(session.percent))
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.text)
                        .minimumScaleFactor(0.6)
                    Text("SESSION")
                        .font(.system(size: 8, weight: .semibold)).tracking(1)
                        .foregroundStyle(Theme.secondary)
                    if let at = session.resetsAt {
                        Text(ResetFormat.countdown(to: at, now: now))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(.horizontal, 12)
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if let week = usage.week {
                HStack(spacing: 4) {
                    Text("Week").foregroundStyle(Theme.secondary)
                    Text(pct(week.percent)).foregroundStyle(Theme.tint(for: week.percent))
                }
                .font(.caption.weight(.semibold))
            }
        }
    }
}

struct MediumView: View {
    let usage: Usage
    let session: Usage.Limit
    let now: Date

    var body: some View {
        HStack(spacing: 18) {
            VStack(spacing: 6) {
                WidgetRing(percent: session.percent, lineWidth: 11) {
                    VStack(spacing: 0) {
                        Text(pct(session.percent))
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(Theme.text)
                        Text("SESSION").font(.system(size: 8, weight: .semibold)).tracking(1)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                .padding(6)
                if let at = session.resetsAt {
                    Text("Resets in \(ResetFormat.countdown(to: at, now: now))")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 112)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 5) {
                    HangarMark().fill(Theme.accent).frame(width: 12, height: 12)
                    Text("This week").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                }
                ForEach(weekly) { limit in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(name(limit)).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            Spacer()
                            Text(pct(limit.percent))
                                .font(.system(.subheadline, design: .rounded, weight: .bold))
                                .foregroundStyle(Theme.tint(for: limit.percent))
                        }
                        WidgetBar(percent: limit.percent)
                    }
                }
                if let at = weekly.compactMap(\.resetsAt).max() {
                    Text("Resets in \(ResetFormat.countdown(to: at, now: now))")
                        .font(.caption2).foregroundStyle(Theme.secondary)
                }
            }
        }
    }

    private var weekly: [Usage.Limit] {
        Array(usage.limits.filter { $0.id != session.id }.prefix(2))
    }

    // "Current week (all models)" -> "All models"
    private func name(_ l: Usage.Limit) -> String {
        guard let open = l.label.firstIndex(of: "(") else { return l.label }
        let s = l.label[l.label.index(after: open)...].trimmingCharacters(in: CharacterSet(charactersIn: ") "))
        return s.prefix(1).uppercased() + s.dropFirst()
    }
}

struct CircularView: View {
    let session: Usage.Limit
    var body: some View {
        Gauge(value: min(session.percent, 100), in: 0...100) {
            HangarMark()
        } currentValueLabel: {
            Text("\(Int(session.percent.rounded()))")
                .font(.system(.title3, design: .rounded, weight: .bold))
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .widgetAccentable()
    }
}

struct RectangularView: View {
    let usage: Usage
    let session: Usage.Limit
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            row("Session", session.percent)
            if let week = usage.week { row("Week", week.percent) }
            if let at = session.resetsAt {
                Text("Session resets in \(ResetFormat.countdown(to: at, now: now))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ p: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).frame(width: 52, alignment: .leading)
            Gauge(value: min(p, 100), in: 0...100) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .widgetAccentable()
            Text(pct(p)).font(.caption.weight(.bold)).monospacedDigit()
        }
    }
}

struct InlineView: View {
    let usage: Usage
    let session: Usage.Limit
    var body: some View {
        if let week = usage.week {
            Text("Session \(pct(session.percent)) · week \(pct(week.percent))")
        } else {
            Text("Session \(pct(session.percent))")
        }
    }
}

// MARK: - Widget

struct UsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HangarLimits", provider: Provider()) { entry in
            UsageWidgetView(entry: entry)
                .containerBackground(for: .widget) { WidgetBackground() }
        }
        .configurationDisplayName("Usage limits")
        .description("How much of your session and weekly limits is used.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

private struct WidgetBackground: View {
    @Environment(\.widgetFamily) private var family
    var body: some View {
        switch family {
        case .systemSmall, .systemMedium:
            ZStack {
                LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [Theme.accentSoft.opacity(0.16), .clear], center: .top, startRadius: 0, endRadius: 180)
            }
        default:
            Color.clear
        }
    }
}

@main
struct UsageWidgetBundle: WidgetBundle {
    var body: some Widget {
        UsageWidget()
    }
}

#Preview(as: .systemSmall) { UsageWidget() } timeline: { UsageEntry(date: .now, usage: .sample) }
#Preview(as: .systemMedium) { UsageWidget() } timeline: { UsageEntry(date: .now, usage: .sample) }
