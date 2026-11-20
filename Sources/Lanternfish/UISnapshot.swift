import AppKit
import CoreImage
import SwiftUI

/// Debug aid: writes a PNG of the app's own window after a delay.
///   LANTERNFISH_SNAPSHOT=/path.png   LANTERNFISH_SNAPSHOT_DELAY=seconds (default 4)
/// Needs no screen-recording permission because it draws our own layer tree.
///
/// `CALayer.render(in:)` ignores Core Animation filters. On macOS 26+ the inspector sits in a
/// Liquid Glass pane whose content is drawn with *vibrancy* filters (a colour matrix per layer:
/// section backgrounds are plain white, text is black, and the filter maps them to the final
/// colours). Rendered naively the inspector comes out as a blank white sheet — a snapshot
/// artifact, not a UI bug. For glass panes we therefore walk the layer tree ourselves and
/// apply each layer's vibrant colour matrix with Core Image.
///
/// Elsewhere (`Baker`) the same window-server effects are baked into plain stand-in layers
/// before rendering: vibrant icons / selection shapes (the selected segment of a glass
/// segmented control otherwise renders as a solid blob), `destOut` knockout groups, and
/// SwiftUI materials (a real blur of what lies behind, instead of nothing — so screenshots
/// show how much of the background actually bleeds through a panel).
///   LANTERNFISH_SNAPSHOT_LAYERS=/path.txt  also dumps the layer tree (filters, blend modes).
enum UISnapshot {
    @MainActor
    static func scheduleIfRequested() {
        let env = DebugEnv.values
        guard let path = env["LANTERNFISH_SNAPSHOT"] else { return }
        let delay = DebugEnv.seconds("LANTERNFISH_SNAPSHOT_DELAY", default: 4)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil }),
                let view = window.contentView?.superview ?? window.contentView
            else { return }
            writePNG(of: view, scale: window.backingScaleFactor, to: path)
            if let dump = env["LANTERNFISH_SNAPSHOT_LAYERS"], let layer = view.layer {
                try? describe(layer).write(toFile: dump, atomically: true, encoding: .utf8)
            }
        }
    }

    /// Debug aid (LANTERNFISH_SNAPSHOT_LAYERS=/path.txt): the layer tree with the properties that
    /// `render(in:)` ignores (filters, compositing filters, backdrop layers).
    @MainActor
    static func describe(_ layer: CALayer, depth: Int = 0) -> String {
        var line = String(repeating: "  ", count: depth) + String(describing: type(of: layer))
        if let d = layer.delegate { line += " <\(type(of: d))>" }
        line += " \(layer.frame.integral)"
        if layer.isHidden { line += " hidden" }
        if layer.opacity < 1 { line += " opacity=\(layer.opacity)" }
        if let c = layer.backgroundColor { line += " bg=\(c.components?.map { String(format: "%.2f", $0) } ?? [])" }
        if layer.contents != nil { line += " contents" }
        if let f = layer.compositingFilter { line += " compositing=\(f)" }
        if let fs = layer.filters, !fs.isEmpty {
            line += " filters=\(fs.map { ($0 as AnyObject).value(forKey: "name") ?? $0 })"
        }
        if let fs = layer.backgroundFilters, !fs.isEmpty {
            line += " bgfilters=\(fs.map { ($0 as AnyObject).value(forKey: "name") ?? $0 })"
        }
        if layer.mask != nil { line += " mask" }
        if let m = Flattener.colorMatrix(of: layer) {
            line += " matrix=\(m.map { String(format: "%.2f", $0) }.joined(separator: ","))"
        }
        return ([line] + (layer.sublayers ?? []).map { describe($0, depth: depth + 1) }).joined(separator: "\n")
    }

    @MainActor
    static func snapshot(_ view: NSView, scale: CGFloat) -> NSBitmapImageRep? {
        let size = view.bounds.size
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let ctx = NSGraphicsContext(bitmapImageRep: rep)?.cgContext
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Large glass panes (the inspector): hide them for the main pass, draw them flattened after.
        let panes = descendants(of: view).compactMap { $0 as? NSGlassEffectView }
            .filter { $0.bounds.height > 150 && !$0.isHiddenOrHasHiddenAncestor && $0.contentView != nil }
        let paneLayers = panes.compactMap(\.layer)

        // Everywhere else, bake what the window server would composite into plain layers:
        // SwiftUI materials (blurred backdrops) and vibrant layers (e.g. the selected segment
        // of a glass segmented control, which is a white shape tinted by a colour matrix —
        // drawn raw it becomes a solid white blob over the segment's icon).
        var baker = Baker(view: view, scale: scale, skip: paneLayers)
        if let root = view.layer {
            baker.bakeMaterials(in: root)
            baker.bakeVibrancy(in: root)
            baker.bakeKnockouts(in: root)
        }
        defer { baker.restore() }

        for pane in panes { pane.layer?.isHidden = true }
        render(view, in: ctx, rect: view.bounds)
        for pane in panes { pane.layer?.isHidden = false }

        for pane in panes {
            guard let content = pane.contentView, let layer = content.layer else { continue }
            let rect = content.convert(content.bounds, to: view)
            ctx.saveGState()
            ctx.clip(to: rect)
            let backdrop = windowBackdrop(of: view)
            ctx.setFillColor(CGColor(srgbRed: backdrop[0], green: backdrop[1], blue: backdrop[2], alpha: 1))
            ctx.fill(rect)
            ctx.translateBy(x: rect.minX, y: rect.minY)
            if content.isFlipped {
                ctx.translateBy(x: 0, y: rect.height)
                ctx.scaleBy(x: 1, y: -1)
            }
            Flattener(root: layer, scale: scale, backdrop: backdrop).draw(layer, in: ctx)
            ctx.restoreGState()
        }
        // The panes extend under the toolbar: redraw the title bar on top.
        if !panes.isEmpty,
            let titlebar = descendants(of: view)
                .first(where: { String(describing: type(of: $0)) == "NSTitlebarContainerView" })
        {
            render(titlebar, in: ctx, rect: titlebar.convert(titlebar.bounds, to: view))
        }
        return rep
    }

    /// Renders `v`'s layer into `rect` of a y-up context.
    @MainActor
    fileprivate static func render(_ v: NSView, in ctx: CGContext, rect: CGRect) {
        guard let layer = v.layer else { return }
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.minY)
        if v.isFlipped {
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
        }
        layer.render(in: ctx)
        ctx.restoreGState()
    }

    @MainActor
    private static func descendants(of v: NSView) -> [NSView] {
        v.subviews + v.subviews.flatMap(descendants)
    }

    /// Snapshots `view` (see `snapshot(_:scale:)`) to a PNG file. Returns whether it was written.
    @MainActor
    @discardableResult
    static func writePNG(of view: NSView, scale: CGFloat, to path: String) -> Bool {
        guard let data = snapshot(view, scale: scale)?.representation(using: .png, properties: [:]) else {
            return false
        }
        return (try? data.write(to: URL(fileURLWithPath: path))) != nil
    }
}

/// Hosts a SwiftUI view in an offscreen window and writes it as a PNG via `UISnapshot`
/// (renders AppKit-backed controls, which `ImageRenderer` can't).
@MainActor
enum OffscreenRenderer {
    private static var windows: [NSWindow] = []

    static func render(_ view: some View, to path: String, settle: Duration = .seconds(1.5)) {
        var root = AnyView(view.background(.windowBackground))
        if let scheme = DebugEnv.colorScheme { root = AnyView(root.environment(\.colorScheme, scheme)) }
        let host = NSHostingView(rootView: root)
        let size = host.fittingSize
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        if let scheme = DebugEnv.colorScheme {
            let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.appearance = appearance
            host.appearance = appearance
        }
        window.orderFrontRegardless()
        windows.append(window)
        Task { @MainActor in
            try? await Task.sleep(for: settle)
            host.frame.size = host.fittingSize
            window.setContentSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            if UISnapshot.writePNG(of: host, scale: window.backingScaleFactor, to: path) {
                alertsLog("wrote %@", path)
            }
            window.orderOut(nil)
            windows.removeAll { $0 === window }
        }
    }
}

// MARK: - Drawing helpers

/// An sRGB bitmap context with premultiplied alpha.
private func bitmapContext(width: Int, height: Int) -> CGContext? {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
}

/// The window background colour of `view`'s appearance as opaque sRGB components.
@MainActor
private func windowBackdrop(of view: NSView) -> [CGFloat] {
    var backdrop: [CGFloat] = [0, 0, 0, 1]
    view.effectiveAppearance.performAsCurrentDrawingAppearance {
        let c = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .black
        backdrop = [c.redComponent, c.greenComponent, c.blueComponent, 1]
    }
    return backdrop
}

/// Renders only `layer`'s own content (its sublayers hidden meanwhile).
@MainActor
private func renderOwnContent(of layer: CALayer, in ctx: CGContext) {
    let subs = layer.sublayers ?? []
    let hidden = subs.map(\.isHidden)
    for s in subs { s.isHidden = true }
    layer.render(in: ctx)
    for (s, wasHidden) in zip(subs, hidden) { s.isHidden = wasHidden }
}

/// What a vibrant colour matrix produces: it is applied to what lies *behind* a layer, and the
/// layer itself only supplies coverage. Fills `coverage`'s alpha with the matrix applied to
/// `backdrop` (sRGB, opaque).
private func fillCoverage(_ coverage: CGImage, matrix: [CGFloat], backdrop b: [CGFloat], ci: CIContext) -> CGImage? {
    func row(_ r: Int) -> CGFloat {
        (0..<4).reduce(matrix[r * 5 + 4]) { $0 + matrix[r * 5 + $1] * b[$1] }
    }
    let color = (0..<4).map { min(max(row($0), 0), 1) }
    let f = CIFilter(name: "CIColorMatrix")!
    f.setValue(CIImage(cgImage: coverage), forKey: kCIInputImageKey)
    f.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputRVector")
    f.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputGVector")
    f.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBVector")
    f.setValue(CIVector(x: 0, y: 0, z: 0, w: color[3]), forKey: "inputAVector")
    f.setValue(CIVector(x: color[0], y: color[1], z: color[2], w: 0), forKey: "inputBiasVector")
    let clamp = CIFilter(name: "CIColorClamp")!
    clamp.setValue(f.outputImage, forKey: kCIInputImageKey)
    guard let out = clamp.outputImage else { return nil }
    return ci.createCGImage(out, from: CGRect(x: 0, y: 0, width: coverage.width, height: coverage.height))
}

/// Temporarily rewrites layers whose look comes from window-server compositing (backdrop
/// blur, vibrant colour matrices, blend modes) — all ignored by `CALayer.render(in:)` — into
/// plain layers with equivalent baked contents, so the snapshot shows what the screen shows.
/// Everything is undone by `restore()` within the same (action-less) transaction.
@MainActor
private struct Baker {
    let view: NSView
    let scale: CGFloat
    /// Subtrees handled by the glass-pane flattener instead.
    let skip: [CALayer]
    private var undo: [() -> Void] = []
    private let ci = CIContext()

    init(view: NSView, scale: CGFloat, skip: [CALayer]) {
        self.view = view
        self.scale = scale
        self.skip = skip
    }

    mutating func restore() {
        for u in undo.reversed() { u() }
        undo.removeAll()
    }

    private func visibleLayers(_ root: CALayer) -> [CALayer] {
        var out: [CALayer] = []
        func walk(_ l: CALayer) {
            guard !l.isHidden, l.opacity > 0.01, !skip.contains(where: { $0 === l }) else { return }
            out.append(l)
            for s in l.sublayers ?? [] { walk(s) }
        }
        walk(root)
        return out
    }

    private static func filter(_ layer: CALayer, named name: String) -> AnyObject? {
        (layer.filters ?? []).map { $0 as AnyObject }
            .first { ($0.value(forKey: "name") as? String) == name || "\($0)".contains(name) }
    }

    /// Renders the window with `target` and everything painted after it hidden: what lies
    /// behind `target`.
    private func renderBehind(_ target: CALayer, root: CALayer) -> CGImage? {
        var hidden: [CALayer] = []
        func walk(_ l: CALayer) -> Bool {
            if l === target { return true }
            var found = false
            for s in l.sublayers ?? [] {
                if found {
                    if !s.isHidden {
                        s.isHidden = true
                        hidden.append(s)
                    }
                } else if walk(s) {
                    found = true
                }
            }
            return found
        }
        let wasHidden = target.isHidden
        target.isHidden = true
        _ = walk(root)
        defer {
            for l in hidden { l.isHidden = false }
            target.isHidden = wasHidden
        }
        let size = view.bounds.size
        let w = Int(size.width * scale)
        let h = Int(size.height * scale)
        guard
            let ctx = bitmapContext(width: w, height: h)
        else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        // Opaque window background underneath, like the screen.
        view.effectiveAppearance.performAsCurrentDrawingAppearance {
            ctx.setFillColor(NSColor.windowBackgroundColor.cgColor)
        }
        ctx.fill(CGRect(origin: .zero, size: size))
        UISnapshot.render(view, in: ctx, rect: view.bounds)
        return ctx.makeImage()
    }

    /// The layer's frame in the view, y-down (top-left origin, like the bitmap's rows).
    private func rectInView(_ layer: CALayer, root: CALayer) -> CGRect {
        let r = layer.convert(layer.bounds, to: root)
        // The root layer's coordinates follow the view's flippedness.
        return view.isFlipped ? r : CGRect(x: r.minX, y: view.bounds.height - r.maxY, width: r.width, height: r.height)
    }

    /// Adds a plain layer showing `image` just above `layer` (same frame) and hides `layer`.
    @discardableResult
    private mutating func replace(_ layer: CALayer, with image: CGImage, hiding extra: [CALayer] = []) -> CALayer? {
        guard let parent = layer.superlayer else { return nil }
        let stand = CALayer()
        stand.frame = layer.frame
        stand.contents = image
        stand.contentsGravity = .resize
        stand.contentsScale = scale
        stand.cornerRadius = layer.cornerRadius
        stand.cornerCurve = layer.cornerCurve
        stand.masksToBounds = layer.masksToBounds
        parent.insertSublayer(stand, above: layer)
        let hide = [layer] + extra.filter { !$0.isHidden }
        for l in hide { l.isHidden = true }
        undo.append {
            stand.removeFromSuperlayer()
            for l in hide { l.isHidden = false }
        }
        return stand
    }

    /// SwiftUI materials: a `CABackdropLayer` (blur + saturation of what's behind, tinted by
    /// its background colour), usually followed by sibling tint layers with blend modes.
    mutating func bakeMaterials(in root: CALayer) {
        let backdrops = visibleLayers(root).filter {
            String(describing: type(of: $0)) == "CABackdropLayer"
                && $0.bounds.width >= 24 && $0.bounds.height >= 16
                && Self.filter($0, named: "gaussianBlur") != nil
                && $0.delegate.map { String(describing: type(of: $0)).contains("SwiftUI") } == true
        }
        for b in backdrops {
            guard let behind = renderBehind(b, root: root) else { continue }
            let r = rectInView(b, root: root)
            let px = CGRect(x: r.minX * scale, y: r.minY * scale, width: r.width * scale, height: r.height * scale)
                .integral
            // CIImage has a bottom-left origin.
            let full = CIImage(cgImage: behind)
            let ciRect = CGRect(x: px.minX, y: full.extent.height - px.maxY, width: px.width, height: px.height)
            var img = full.clampedToExtent()
            let radius =
                (Self.filter(b, named: "gaussianBlur")?.value(forKey: "inputRadius") as? NSNumber)
                .map { CGFloat(truncating: $0) } ?? 30
            img = img.applyingGaussianBlur(sigma: Double(radius * scale / 2))
            if let sat = Self.filter(b, named: "colorSaturate")?.value(forKey: "inputAmount") as? NSNumber {
                img = img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: sat])
            }
            img = img.cropped(to: ciRect)
            guard let blurred = ci.createCGImage(img, from: ciRect),
                let ctx = bitmapContext(width: Int(px.width), height: Int(px.height))
            else { continue }
            let box = CGRect(x: 0, y: 0, width: px.width, height: px.height)
            ctx.draw(blurred, in: box)
            if let bg = b.backgroundColor {
                ctx.setFillColor(bg)
                ctx.fill(box)
            }
            // Following siblings that blend onto the material (e.g. a lighten-mode tint).
            var blended: [CALayer] = []
            if let subs = b.superlayer?.sublayers, let i = subs.firstIndex(where: { $0 === b }) {
                for s in subs[(i + 1)...] {
                    guard let mode = Self.blendMode(s.compositingFilter), s.frame == b.frame,
                        (s.sublayers ?? []).isEmpty, !s.isHidden
                    else { break }
                    if let c = s.backgroundColor {
                        ctx.setBlendMode(mode)
                        ctx.setAlpha(CGFloat(s.opacity))
                        ctx.setFillColor(c)
                        ctx.fill(box)
                        ctx.setAlpha(1)
                        ctx.setBlendMode(.normal)
                    }
                    blended.append(s)
                }
            }
            guard let baked = ctx.makeImage() else { continue }
            replace(b, with: baked, hiding: blended)
        }
    }

    private static func blendMode(_ filter: Any?) -> CGBlendMode? {
        guard let filter else { return nil }
        let name = (filter as? String) ?? ((filter as AnyObject).value(forKey: "name") as? String) ?? "\(filter)"
        switch name {
        case let n where n.hasPrefix("lighten"): return .lighten
        case let n where n.hasPrefix("darken"): return .darken
        case let n where n.hasPrefix("multiply"): return .multiply
        case let n where n.hasPrefix("screen"): return .screen
        case let n where n.hasPrefix("overlay"): return .overlay
        case let n where n.hasPrefix("plusL"): return .plusLighter
        case let n where n.hasPrefix("plusD"): return .plusDarker
        default: return nil
        }
    }

    /// Layers composited with `destOut` / `destIn` (e.g. a segmented control knocks the
    /// selected segment out of its row of unselected icons) are drawn as plain opaque shapes
    /// by `render(in:)`: the selected segment turns into a solid blob. Composite such groups
    /// ourselves and show the result in place of the group.
    mutating func bakeKnockouts(in root: CALayer) {
        let knockouts = visibleLayers(root).filter { l in
            guard let name = l.compositingFilter.map({ "\($0)" }) else { return false }
            return name.hasPrefix("destOut") || name.hasPrefix("destIn")
        }
        var groups: [CALayer] = []
        for k in knockouts {
            guard let p = k.superlayer, !groups.contains(where: { $0 === p }) else { continue }
            groups.append(p)
        }
        for group in groups {
            let w = Int((group.bounds.width * scale).rounded(.up))
            let h = Int((group.bounds.height * scale).rounded(.up))
            guard w > 0, h > 0, w * h < 4_000_000, let ctx = bitmapContext(width: w, height: h)
            else { continue }
            let subs = group.sublayers ?? []
            let wasHidden = subs.map(\.isHidden)
            let opacity = group.opacity
            group.opacity = 1
            func pass(_ draw: (CALayer) -> Bool, own: Bool) -> CGImage? {
                guard let off = bitmapContext(width: w, height: h) else { return nil }
                off.translateBy(x: 0, y: CGFloat(h))
                off.scaleBy(x: scale, y: -scale)
                off.translateBy(x: -group.bounds.minX, y: -group.bounds.minY)
                let bg = group.backgroundColor
                let contents = group.contents
                if !own {
                    group.backgroundColor = nil
                    group.contents = nil
                }
                for (s, hidden) in zip(subs, wasHidden) { s.isHidden = hidden || !draw(s) }
                group.render(in: off)
                for (s, hidden) in zip(subs, wasHidden) { s.isHidden = hidden }
                if !own {
                    group.backgroundColor = bg
                    group.contents = contents
                }
                return off.makeImage()
            }
            func mode(_ l: CALayer) -> CGBlendMode? {
                guard let name = l.compositingFilter.map({ "\($0)" }) else { return nil }
                return name.hasPrefix("destOut") ? .destinationOut : name.hasPrefix("destIn") ? .destinationIn : nil
            }
            // Everything that isn't a knockout, then each knockout with its blend mode.
            guard let base = pass({ mode($0) == nil }, own: true) else {
                group.opacity = opacity
                continue
            }
            let box = CGRect(x: 0, y: 0, width: w, height: h)
            ctx.draw(base, in: box)
            for k in subs where mode(k) != nil && !k.isHidden {
                // The knockout's own subtree, drawn normally (its compositing filter is ignored).
                guard let img = pass({ $0 === k }, own: false) else { continue }
                ctx.setBlendMode(mode(k)!)
                ctx.draw(img, in: box)
                ctx.setBlendMode(.normal)
            }
            group.opacity = opacity
            guard let baked = ctx.makeImage() else { continue }
            // The stand-in carries the group's opacity.
            replace(group, with: baked)?.opacity = opacity
        }
    }

    /// Vibrant layers: their own content only supplies coverage; the colour comes from a
    /// matrix applied to what's behind. Approximate the backdrop with the window colour.
    mutating func bakeVibrancy(in root: CALayer) {
        let backdrop = windowBackdrop(of: view)
        for layer in visibleLayers(root)
        where Self.filter(layer, named: "vibrantColorMatrix") != nil
            && String(describing: type(of: layer)) != "CABackdropLayer"
            // Glass platters (a tinted shape whose portal re-shows the content above it):
            // baked they'd cover the toolbar items; left alone `render(in:)` skips them.
            && !(layer.sublayers ?? []).contains(where: { String(describing: type(of: $0)).contains("Portal") })
        {
            // Leaf layers only (icons, glyphs, selection shapes): hiding the original hides its subtree.
            guard (layer.sublayers ?? []).allSatisfy(\.isHidden),
                let matrix = Flattener.colorMatrix(of: layer), layer.bounds.width >= 1, layer.bounds.height >= 1,
                let baked = Self.recolor(layer, matrix: matrix, backdrop: backdrop, scale: scale, ci: ci)
            else { continue }
            // `render(in:)` ignores new `contents` on SwiftUI-managed layers, so show the baked
            // image in a plain stand-in and hide the original.
            replace(layer, with: baked)?.opacity = layer.opacity
        }
    }

    /// The layer's own content (no sublayers) as coverage, filled with the matrix colour.
    private static func recolor(
        _ layer: CALayer, matrix: [CGFloat], backdrop b: [CGFloat], scale: CGFloat, ci: CIContext
    )
        -> CGImage?
    {
        let w = Int((layer.bounds.width * scale).rounded(.up))
        let h = Int((layer.bounds.height * scale).rounded(.up))
        guard let off = bitmapContext(width: w, height: h) else { return nil }
        // Flip so the bitmap's first row is the layer's top, as `contents` expects.
        off.translateBy(x: 0, y: CGFloat(h))
        off.scaleBy(x: scale, y: -scale)
        off.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        let opacity = layer.opacity
        layer.opacity = 1
        renderOwnContent(of: layer, in: off)
        layer.opacity = opacity
        guard let raw = off.makeImage() else { return nil }
        return fillCoverage(raw, matrix: matrix, backdrop: b, ci: ci)
    }
}

/// Draws a layer tree one layer at a time (in root-layer coordinates), applying vibrant
/// colour-matrix filters that `CALayer.render(in:)` would ignore.
@MainActor
private struct Flattener {
    let root: CALayer
    let scale: CGFloat
    /// Approximate colour behind the pane (sRGB, opaque).
    let backdrop: [CGFloat]
    let ci = CIContext()
    /// Window-server-composited layers that `render(in:)` can't draw.
    static let skipped: Set<String> = ["CABackdropLayer", "CAPortalLayer"]

    func draw(_ layer: CALayer, in ctx: CGContext) {
        guard !layer.isHidden, layer.opacity > 0.01,
            !Self.skipped.contains(String(describing: type(of: layer)))
        else { return }
        let rect = layer.convert(layer.bounds, to: root)
        let subs = layer.sublayers ?? []

        ctx.saveGState()
        ctx.setAlpha(CGFloat(layer.opacity))
        if let matrix = Self.colorMatrix(of: layer) {
            drawFiltered(layer, rect: rect, matrix: matrix, in: ctx)
        } else {
            ctx.saveGState()
            ctx.translateBy(x: rect.minX, y: rect.maxY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
            renderOwnContent(of: layer, in: ctx)
            ctx.restoreGState()
        }
        if layer.masksToBounds { ctx.clip(to: rect) }
        for s in subs { draw(s, in: ctx) }
        ctx.restoreGState()
    }

    private func drawFiltered(_ layer: CALayer, rect: CGRect, matrix: [CGFloat], in ctx: CGContext) {
        let w = Int((rect.width * scale).rounded(.up))
        let h = Int((rect.height * scale).rounded(.up))
        guard w > 0, h > 0, let off = bitmapContext(width: w, height: h) else { return }
        off.scaleBy(x: scale, y: scale)
        off.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        renderOwnContent(of: layer, in: off)
        // The pane colour stands in for what lies behind the layer.
        guard let raw = off.makeImage(), let img = fillCoverage(raw, matrix: matrix, backdrop: backdrop, ci: ci)
        else { return }

        // `ctx` is y-down here; flip locally so the bitmap lands upright.
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    /// The 4×5 matrix of a `vibrantColorMatrix` filter, if the layer has one.
    static func colorMatrix(of layer: CALayer) -> [CGFloat]? {
        for filter in layer.filters ?? [] {
            guard let value = (filter as AnyObject).value(forKey: "inputColorMatrix") as? NSValue else { continue }
            var buf = [Float](repeating: 0, count: 20)
            buf.withUnsafeMutableBytes { value.getValue($0.baseAddress!, size: 80) }
            return buf.map { CGFloat($0) }
        }
        return nil
    }
}
