import AppKit
import SwiftUI

/// The lanternfish from the app icon, as geometry shared by the scanning indicator and the menu
/// bar glyph. Drawn in a 100 × 50 box with the nose at +x (y down).
enum LanternfishGlyph {
    static let box = CGSize(width: 100, height: 50)

    /// Body and tail, wound the same way so their overlap fills.
    static func outline(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 10, y: 25))
        p.addCurve(to: CGPoint(x: 80, y: 11), control1: CGPoint(x: 22, y: 9), control2: CGPoint(x: 56, y: 5))
        p.addCurve(to: CGPoint(x: 99, y: 26), control1: CGPoint(x: 92, y: 14), control2: CGPoint(x: 99, y: 20))
        p.addCurve(to: CGPoint(x: 80, y: 39), control1: CGPoint(x: 99, y: 32), control2: CGPoint(x: 92, y: 37))
        p.addCurve(to: CGPoint(x: 10, y: 25), control1: CGPoint(x: 56, y: 45), control2: CGPoint(x: 22, y: 41))
        p.closeSubpath()
        p.move(to: CGPoint(x: 16, y: 25))
        p.addLine(to: CGPoint(x: 1, y: 38))
        p.addQuadCurve(to: CGPoint(x: 1, y: 12), control: CGPoint(x: 6, y: 25))
        p.closeSubpath()
        return p.applying(transform(into: rect))
    }

    static let eye = CGPoint(x: 84, y: 22)

    /// The photophores along the belly, tail to nose.
    static let lights: [CGPoint] = [
        CGPoint(x: 34, y: 33), CGPoint(x: 47, y: 34.5), CGPoint(x: 60, y: 34.5), CGPoint(x: 73, y: 33),
    ]

    /// Maps the glyph's box onto `rect`, keeping its aspect ratio and centring it.
    static func transform(into rect: CGRect) -> CGAffineTransform {
        let scale = min(rect.width / box.width, rect.height / box.height)
        let x = rect.midX - box.width * scale / 2
        let y = rect.midY - box.height * scale / 2
        return CGAffineTransform(translationX: x, y: y).scaledBy(x: scale, y: scale)
    }

    /// Template image for the menu bar: the fish with its eye cut out, and its lights too while a
    /// scan runs (`lit`).
    static func menuBarImage(lit: Bool) -> NSImage {
        let size = NSSize(width: 22, height: 16)
        let image = NSImage(size: size, flipped: true) { bounds in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let rect = bounds.insetBy(dx: 0.5, dy: 2)
            let t = transform(into: rect)
            ctx.addPath(outline(in: rect).cgPath)
            ctx.setFillColor(.black)
            ctx.fillPath()
            ctx.setBlendMode(.clear)
            let eyeCenter = eye.applying(t)
            ctx.fillEllipse(in: CGRect(x: eyeCenter.x - 1.3, y: eyeCenter.y - 1.3, width: 2.6, height: 2.6))
            for light in lights where lit {
                let c = light.applying(t)
                ctx.fillEllipse(in: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Lanternfish"
        return image
    }
}

/// Shown in the toolbar while a scan runs: the lanternfish with its lights glowing one after
/// another, tail to nose. Driven by a `TimelineView` that only exists while the view is shown;
/// with Reduce Motion the lights stay on.
struct LanternPulse: View {
    var size: CGFloat = 16
    /// Seconds for one pass of light along the fish.
    var period: Double = 1.4
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The icon's glow cyan; deeper in light mode so it reads on white.
    private static let light = Color(
        nsColor: NSColor(name: "LanternLight") { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(srgbRed: 0.31, green: 0.90, blue: 0.96, alpha: 1)
                : NSColor(srgbRed: 0.0, green: 0.55, blue: 0.70, alpha: 1)
        })

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { timeline in
            let phase = (timeline.date.timeIntervalSinceReferenceDate / period).truncatingRemainder(dividingBy: 1)
            Canvas { ctx, canvas in draw(&ctx, in: CGRect(origin: .zero, size: canvas), phase: phase) }
        }
        .frame(width: size * 1.4, height: size)
        .accessibilityElement()
        .accessibilityLabel("Scanning")
    }

    private func draw(_ ctx: inout GraphicsContext, in rect: CGRect, phase: Double) {
        let t = LanternfishGlyph.transform(into: rect)
        let scale = t.a
        ctx.fill(LanternfishGlyph.outline(in: rect), with: .color(.secondary.opacity(0.7)))
        let count = Double(LanternfishGlyph.lights.count)
        for (i, light) in LanternfishGlyph.lights.enumerated() {
            // Each light peaks as the pulse passes it; with Reduce Motion all stay half lit.
            let distance = abs(phase * (count + 1) - Double(i) - 0.5)
            let level = reduceMotion ? 0.7 : max(0.25, 1 - distance / 1.6)
            let c = light.applying(t)
            let r = 5.5 * scale
            let glow = Path(ellipseIn: CGRect(x: c.x - 2 * r, y: c.y - 2 * r, width: 4 * r, height: 4 * r))
            ctx.fill(glow, with: .color(Self.light.opacity(0.4 * level)))
            let dot = Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            ctx.fill(dot, with: .color(Self.light.opacity(level)))
        }
    }
}

/// "Looking for devices…": the first scan of a network before anything but this Mac answered.
struct ScanningPlaceholder: View {
    /// The subnet being swept, e.g. "192.168.1.0/24".
    var subnet: String?

    var body: some View {
        VStack(spacing: 14) {
            LanternPulse(size: 48, period: 1.8)
            VStack(spacing: 4) {
                Text("Looking for Devices…")
                    .font(.title3.weight(.semibold))
                Text(
                    subnet.map { "Sweeping \($0). Devices appear here as they answer." }
                        ?? "Devices appear here as they answer."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }
        }
        .padding(24)
        .frame(maxWidth: 360)
        .accessibilityElement(children: .combine)
    }
}
