import SwiftUI

/// Compact version of claude-monitor's screen: one bar per limit with its reset countdown.
struct LimitsCard: View {
    let usage: Usage?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let usage {
                ForEach(usage.limits) { LimitRow(limit: $0) }
            } else if let error {
                Label("Limits unavailable", systemImage: "gauge.with.dots.needle.0percent")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.amber)
                Text(error).font(.caption).foregroundStyle(Theme.secondary)
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        }
        .padding(.vertical, 6)
    }
}

struct LimitRow: View {
    let limit: Usage.Limit

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(limit.shortLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.cream)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { ctx in
                    if let at = limit.resetsAt {
                        Text("resets in \(ResetFormat.countdown(to: at, now: ctx.date))")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.secondary)
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(Theme.tint(for: limit.percent))
                    .contentTransition(.numericText(value: limit.percent))
                    .animation(.snappy, value: limit.percent)
                    .frame(minWidth: 52, alignment: .trailing)
            }
            BarGauge(percent: limit.percent)
        }
    }
}

struct BarGauge: View {
    let percent: Double
    @State private var shown: Double = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                Capsule()
                    .fill(LinearGradient(colors: Theme.gradient(for: percent), startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(8, geo.size.width * shown / 100))
                    .shadow(color: Theme.gradient(for: percent)[0].opacity(0.5), radius: 5)
            }
        }
        .frame(height: 8)
        .onAppear { withAnimation(.spring(response: 1.0, dampingFraction: 0.85).delay(0.15)) { shown = min(percent, 100) } }
        .onChange(of: percent) { _, new in withAnimation(.spring) { shown = min(new, 100) } }
    }
}
