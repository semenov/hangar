import SwiftUI

/// Night-blue palette with mint accents.
enum Theme {
    static let accent = Color(red: 0.302, green: 0.851, blue: 0.702)     // mint
    static let accentSoft = Color(red: 0.333, green: 0.722, blue: 1.0)   // sky
    static let amber = Color(red: 0.976, green: 0.761, blue: 0.333)
    static let red = Color(red: 0.961, green: 0.408, blue: 0.439)
    static let text = Color(red: 0.906, green: 0.937, blue: 0.965)
    static let bgTop = Color(red: 0.118, green: 0.157, blue: 0.420)  // indigo, as in the icon
    static let bgBottom = Color(red: 0.035, green: 0.051, blue: 0.137)
    static let card = Color.white.opacity(0.05)
    static let track = Color.white.opacity(0.08)
    static let secondary = text.opacity(0.55)
    static let green = Color(red: 0.302, green: 0.851, blue: 0.702)

    /// Gauge colors shift from mint to amber to red as a limit fills up.
    static func gradient(for percent: Double) -> [Color] {
        switch percent {
        case ..<70: [accent, accentSoft]
        case ..<90: [accentSoft, amber]
        default: [amber, red]
        }
    }

    static func tint(for percent: Double) -> Color {
        switch percent {
        case ..<70: accent
        case ..<90: amber
        default: red
        }
    }
}

struct Background: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Theme.bgTop, Theme.bgBottom], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Theme.accentSoft.opacity(0.3), .clear], center: .init(x: 0.5, y: 0.12),
                           startRadius: 0, endRadius: 380)
        }
        .ignoresSafeArea()
    }
}

/// Hangar's mark, the app icon's silhouette: an arched hangar with its door open.
struct HangarMark: Shape {
    func path(in rect: CGRect) -> Path {
        let s = min(rect.width, rect.height)
        let rx = s / 2, ry = s * 0.5
        let ground = rect.midY + ry / 2
        var arch = Path()
        arch.move(to: CGPoint(x: rect.midX - rx, y: ground))
        arch.addArc(center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false,
                    transform: CGAffineTransform(translationX: rect.midX, y: ground).scaledBy(x: rx, y: ry))
        arch.closeSubpath()
        let dw = rx * 0.95, dh = ry * 0.5
        let door = Path(roundedRect: CGRect(x: rect.midX - dw / 2, y: ground - dh, width: dw, height: dh + 1),
                        cornerRadius: s * 0.04)
        return arch.subtracting(door)
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
            .foregroundStyle(Theme.text)
            .frame(width: 40, height: 40)
            .background(Theme.card, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.08)))
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy, value: configuration.isPressed)
    }
}
