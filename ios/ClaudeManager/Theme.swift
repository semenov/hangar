import SwiftUI

enum Theme {
    static let coral = Color(red: 0.851, green: 0.467, blue: 0.341)
    static let peach = Color(red: 0.961, green: 0.659, blue: 0.502)
    static let amber = Color(red: 0.965, green: 0.722, blue: 0.290)
    static let red = Color(red: 0.937, green: 0.341, blue: 0.318)
    static let cream = Color(red: 0.980, green: 0.925, blue: 0.886)
    static let bgTop = Color(red: 0.110, green: 0.078, blue: 0.067)
    static let bgBottom = Color(red: 0.047, green: 0.039, blue: 0.035)
    static let card = Color.white.opacity(0.05)
    static let track = Color.white.opacity(0.08)
    static let secondary = cream.opacity(0.55)
    static let green = Color(red: 0.494, green: 0.812, blue: 0.533)

    /// Gauge colors shift from coral to amber to red as a limit fills up.
    static func gradient(for percent: Double) -> [Color] {
        switch percent {
        case ..<70: [coral, peach]
        case ..<90: [coral, amber]
        default: [amber, red]
        }
    }

    static func tint(for percent: Double) -> Color {
        switch percent {
        case ..<70: peach
        case ..<90: amber
        default: red
        }
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.coral.opacity(0.22), .clear], center: .init(x: 0.5, y: 0.12),
                           startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

/// Claude-style spark, used as a small brand mark.
struct Spark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<12 {
            let a = Double(i) * .pi / 6 - .pi / 2
            let len = r * (i.isMultiple(of: 2) ? 1 : 0.78)
            p.move(to: CGPoint(x: c.x + cos(a) * r * 0.12, y: c.y + sin(a) * r * 0.12))
            p.addLine(to: CGPoint(x: c.x + cos(a) * len, y: c.y + sin(a) * len))
        }
        return p.strokedPath(StrokeStyle(lineWidth: r * 0.2, lineCap: .round))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: .rect(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(.white.opacity(0.07)))
    }
}

struct CircleButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Theme.cream)
            .frame(width: 40, height: 40)
            .background(Theme.card, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy, value: configuration.isPressed)
    }
}
