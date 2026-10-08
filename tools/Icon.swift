// Renders the 1024x1024 app icon: a hangar at night, its doorway glowing, light spilling onto the
// ground. Run: swift tools/Icon.swift <out.png>
import AppKit
import SwiftUI

let canvas: CGFloat = 1024
let ground: CGFloat = 700

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// Half an ellipse standing on the ground line.
struct Dome: Shape {
    var rx: CGFloat, ry: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: canvas / 2 - rx, y: ground))
        p.addArc(center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false,
                 transform: CGAffineTransform(translationX: canvas / 2, y: ground).scaledBy(x: rx, y: ry))
        p.closeSubpath()
        return p
    }
}

/// Only the curved roof line of a dome, for rims and ribs.
struct Roof: Shape {
    var rx: CGFloat, ry: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.addArc(center: .zero, radius: 1, startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false,
                 transform: CGAffineTransform(translationX: canvas / 2, y: ground).scaledBy(x: rx, y: ry))
        return p
    }
}

/// The doorway: a rectangle with a round top.
struct Door: Shape {
    var width: CGFloat, height: CGFloat
    func path(in rect: CGRect) -> Path {
        let r = width / 2, x0 = canvas / 2 - r
        var p = Path()
        p.move(to: CGPoint(x: x0, y: ground))
        p.addLine(to: CGPoint(x: x0, y: ground - height + r))
        p.addArc(center: CGPoint(x: canvas / 2, y: ground - height + r), radius: r,
                 startAngle: .degrees(180), endAngle: .degrees(360), clockwise: false)
        p.addLine(to: CGPoint(x: x0 + width, y: ground))
        p.closeSubpath()
        return p
    }
}

/// Light thrown from the doorway onto the ground, widening towards the viewer.
struct Spill: Shape {
    var top: CGFloat, bottom: CGFloat
    func path(in rect: CGRect) -> Path {
        let c: CGFloat = canvas / 2, t: CGFloat = top / 2, b: CGFloat = bottom / 2
        var p = Path()
        p.move(to: CGPoint(x: c - t, y: ground))
        p.addLine(to: CGPoint(x: c + t, y: ground))
        p.addLine(to: CGPoint(x: c + b, y: canvas))
        p.addLine(to: CGPoint(x: c - b, y: canvas))
        p.closeSubpath()
        return p
    }
}

struct Icon: View {
    let domeRX: CGFloat = 392, domeRY: CGFloat = 400
    let doorW: CGFloat = 292, doorH: CGFloat = 300

    let mint = Color(hex: 0x5CF2C9)
    let mintDeep = Color(hex: 0x17A88A)
    let glowWhite = Color(hex: 0xF2FFFB)

    var body: some View {
        ZStack {
            // Night sky.
            LinearGradient(colors: [Color(hex: 0x1F3A6E), Color(hex: 0x16305E), Color(hex: 0x0B1834)],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: ground / canvas))
            RadialGradient(colors: [Color(hex: 0x3F78B5, opacity: 0.6), .clear],
                           center: UnitPoint(x: 0.5, y: 0.3), startRadius: 0, endRadius: 560)

            // Ground: a little lighter than the sky right below the horizon.
            Rectangle()
                .fill(LinearGradient(colors: [Color(hex: 0x0D1A33), Color(hex: 0x03050B)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(height: canvas - ground)
                .frame(maxHeight: .infinity, alignment: .bottom)

            // Light on the ground.
            Spill(top: doorW * 0.96, bottom: canvas * 1.05)
                .fill(LinearGradient(colors: [mint.opacity(0.55), mint.opacity(0.12), .clear],
                                     startPoint: UnitPoint(x: 0.5, y: ground / canvas), endPoint: .bottom))
                .blur(radius: 28)
                .blendMode(.screen)

            // Halo of the doorway against the sky and the hangar.
            Door(width: doorW, height: doorH)
                .fill(mint)
                .blur(radius: 70)
                .opacity(0.55)
                .blendMode(.screen)

            // The hangar.
            Dome(rx: domeRX, ry: domeRY)
                .fill(LinearGradient(colors: [Color(hex: 0x0E1830), Color(hex: 0x081022)],
                                     startPoint: UnitPoint(x: 0.5, y: (ground - domeRY) / canvas),
                                     endPoint: UnitPoint(x: 0.5, y: ground / canvas)))
            // Corrugated roof: faint concentric ribs.
            ForEach([0.86, 0.72, 0.58], id: \.self) { k in
                Roof(rx: domeRX * k, ry: domeRY * k)
                    .stroke(Color(hex: 0x6F8FC4, opacity: 0.12), lineWidth: 8)
            }
            // Moonlight on the roof's edge.
            Roof(rx: domeRX - 3, ry: domeRY - 3)
                .stroke(LinearGradient(colors: [Color(hex: 0xBFD6FF, opacity: 0.85), Color(hex: 0x8FB0E8, opacity: 0.25), .clear],
                                       startPoint: UnitPoint(x: 0.5, y: (ground - domeRY) / canvas),
                                       endPoint: UnitPoint(x: 0.5, y: ground / canvas)),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round))
            // Mint light from the doorway catching the inside of the facade.
            Dome(rx: domeRX, ry: domeRY)
                .fill(RadialGradient(colors: [mint.opacity(0.22), .clear],
                                     center: UnitPoint(x: 0.5, y: ground / canvas), startRadius: doorW * 0.4,
                                     endRadius: domeRX * 1.05))
                .blendMode(.screen)

            // Door frame, then the glowing opening.
            Door(width: doorW + 26, height: doorH + 13)
                .fill(Color(hex: 0x070D1C))
            Door(width: doorW, height: doorH)
                .fill(LinearGradient(stops: [
                    .init(color: mintDeep, location: 0),
                    .init(color: mint, location: 0.55),
                    .init(color: glowWhite, location: 1),
                ], startPoint: .top, endPoint: .bottom))
            // Hot core near the floor.
            Ellipse()
                .fill(glowWhite)
                .frame(width: doorW * 0.9, height: 90)
                .position(x: canvas / 2, y: ground - 10)
                .blur(radius: 26)
                .opacity(0.9)
                .mask(Door(width: doorW, height: doorH))

            // Threshold.
            Capsule()
                .fill(LinearGradient(colors: [.clear, glowWhite.opacity(0.9), .clear], startPoint: .leading, endPoint: .trailing))
                .frame(width: doorW * 1.5, height: 5)
                .position(x: canvas / 2, y: ground + 1)
        }
        .frame(width: canvas, height: canvas)
        .clipped()
    }
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"
MainActor.assumeIsolated {
    let renderer = ImageRenderer(content: Icon())
    renderer.scale = 1
    guard let cg = renderer.cgImage else { fatalError("render failed") }
    let rep = NSBitmapImageRep(cgImage: cg)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}
