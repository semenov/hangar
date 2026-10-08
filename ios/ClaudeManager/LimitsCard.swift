import SwiftUI

/// claude-monitor's limits as a row of ring gauges, one per limit.
struct LimitsCard: View {
    let usage: Usage?
    let error: String?

    var body: some View {
        Group {
            if let usage {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(usage.limits) { limit in
                        LimitRing(limit: limit).frame(maxWidth: .infinity)
                    }
                }
            } else if let error {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Limits unavailable", systemImage: "gauge.with.dots.needle.0percent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.amber)
                    Text(error).font(.caption).foregroundStyle(Theme.secondary)
                }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.frame(height: 150)
            }
        }
        .padding(.vertical, 10)
    }
}

struct LimitRing: View {
    let limit: Usage.Limit

    /// "Week · All models" → ("Week", "All models")
    private var title: (String, String?) {
        let parts = limit.shortLabel.components(separatedBy: " · ")
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RingGauge(percent: limit.percent, lineWidth: 9)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text("\(Int(limit.percent.rounded()))")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .contentTransition(.numericText(value: limit.percent))
                    Text("%")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(Theme.secondary)
                }
                .foregroundStyle(Theme.cream)
                .animation(.snappy, value: limit.percent)
            }
            .frame(width: 84, height: 84)

            VStack(spacing: 2) {
                Text(title.0.uppercased())
                    .font(.caption2.weight(.semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.cream)
                Text(title.1 ?? " ")
                    .font(.caption2)
                    .foregroundStyle(Theme.secondary)
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if let at = limit.resetsAt {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.counterclockwise")
                            Text(ResetFormat.countdown(to: at, now: ctx.date))
                        }
                    }
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(Theme.tint(for: limit.percent).opacity(0.85))
                .padding(.top, 2)
            }
            .lineLimit(1)
        }
    }
}

struct RingGauge: View {
    let percent: Double
    var lineWidth: CGFloat = 22

    @State private var shown: Double = 0

    var body: some View {
        let colors = Theme.gradient(for: percent)
        ZStack {
            Circle().stroke(Theme.track, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.004, shown / 100))
                .stroke(
                    AngularGradient(colors: colors + [colors[0]], center: .center,
                                    startAngle: .degrees(0), endAngle: .degrees(360 * max(shown, 1) / 100 + 1)),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: colors[0].opacity(0.55), radius: 8)
        }
        .onAppear { animate(to: percent) }
        .onChange(of: percent) { _, new in animate(to: new) }
    }

    private func animate(to value: Double) {
        withAnimation(.spring(response: 1.1, dampingFraction: 0.85)) { shown = min(value, 100) }
    }
}
