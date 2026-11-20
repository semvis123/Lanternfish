#!/usr/bin/env swift
// Generates the Lanternfish app icon (a glowing school of lanternfish in deep water) and the
// app's asset catalog from code.
//
//   swift scripts/generate-icon.swift
//
// Outputs (all under assets/):
//   AppIcon.iconset/   16…1024 px PNGs (incl. @2x), drawn natively per size
//   AppIcon.icns       built from the iconset with `iconutil`
//   icon-1024.png      full-detail 1024 px master
//   icon.svg           vector version (README)
//   AppIcon.icon/      Icon Composer bundle (layered, Liquid Glass)
//   Colors.xcassets/   the accent colour
//   Assets.car         AppIcon.icon + Colors.xcassets, compiled by `xcrun actool` (Xcode 26+)
//
// The flat artwork follows Apple's macOS icon grid: a 1024 canvas with an 824 pt
// continuous-corner body. Coordinates below are y-down, like the SVG.

import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - Paths

let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = repo.appendingPathComponent("assets")
let iconset = assets.appendingPathComponent("AppIcon.iconset")
let iconBundle = assets.appendingPathComponent("AppIcon.icon")
let colorCatalog = assets.appendingPathComponent("Colors.xcassets")
let fm = FileManager.default

// MARK: - Design

let canvas: CGFloat = 1024
let bodyRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyRadius: CGFloat = 185.4

struct Stop { var at: CGFloat; var hex: UInt32 }
let abyss = [Stop(at: 0, hex: 0x123a63), Stop(at: 0.55, hex: 0x0a1f3d), Stop(at: 1, hex: 0x030814)]
let abyssDark = [Stop(at: 0, hex: 0x0d2b4b), Stop(at: 0.55, hex: 0x07172e), Stop(at: 1, hex: 0x02050d)]
/// Fish bodies shade from the tail to the nose.
let bodyTail: UInt32 = 0x3fd9e8
let bodyNose: UInt32 = 0xb8fbff
let glowColor: UInt32 = 0x4fe6f5
let eyeRing: UInt32 = 0x0a3a5c
let eyeLight: UInt32 = 0xe8feff

/// App accent colour (Colors.xcassets): the fish's cyan, deep enough for white text on it
/// (5.4:1 in light mode, 4.5:1 in dark mode).
let accentLight: UInt32 = 0x007391
let accentDark: UInt32 = 0x0a809f

/// A fish centred at (x, y), `length` long, nose rotated `angle` degrees from +x (clockwise, y-down).
struct Fish { var x: CGFloat; var y: CGFloat; var length: CGFloat; var angle: CGFloat; var alpha: CGFloat }

let lead = Fish(x: 660, y: 440, length: 360, angle: -16, alpha: 1)
/// The school, roughly largest first. `minPixels` drops the smallest fish at small icon sizes.
let school: [(fish: Fish, minPixels: Int)] = [
    (Fish(x: 400, y: 320, length: 196, angle: -10, alpha: 0.75), 16),
    (Fish(x: 400, y: 575, length: 196, angle: -20, alpha: 0.75), 32),
    (Fish(x: 215, y: 445, length: 144, angle: -14, alpha: 0.55), 64),
    (Fish(x: 640, y: 690, length: 144, angle: -24, alpha: 0.55), 64),
    (Fish(x: 245, y: 235, length: 136, angle: -8, alpha: 0.5), 128),
    (Fish(x: 205, y: 650, length: 104, angle: -18, alpha: 0.4), 128),
    (Fish(x: 790, y: 235, length: 104, angle: -12, alpha: 0.4), 128),
]

/// Lanternfish outline in a 100 × 50 box, nose at +x: a blunt-headed body and a forked tail,
/// wound the same way so their overlap fills. Same shape as `LanternfishGlyph` in the app.
func fishPath() -> CGPath {
    let p = CGMutablePath()
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
    return p
}
let fishSVGPath =
    "M10 25 C22 9 56 5 80 11 C92 14 99 20 99 26 C99 32 92 37 80 39 C56 45 22 41 10 25 Z M16 25 L1 38 Q6 25 1 12 Z"
let eyeCenter = CGPoint(x: 86, y: 22)

func fishTransform(_ f: Fish) -> CGAffineTransform {
    let scale = f.length / 100
    return CGAffineTransform(translationX: f.x, y: f.y)
        .rotated(by: f.angle * .pi / 180)
        .translatedBy(x: -f.length / 2, y: -f.length / 4)
        .scaledBy(x: scale, y: scale)
}

// MARK: - Drawing

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

func gradient(_ stops: [Stop]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: stops.map { color($0.hex) } as CFArray,
        locations: stops.map(\.at))!
}

struct Parts: OptionSet {
    let rawValue: Int
    static let background = Parts(rawValue: 1 << 0)
    static let glow = Parts(rawValue: 1 << 1)
    static let school = Parts(rawValue: 1 << 2)
    static let lead = Parts(rawValue: 1 << 3)
    static let all: Parts = [.background, .glow, .school, .lead]
}

/// The fish body with its tail-to-nose gradient, plus the eye when `eye` is set.
func drawFish(_ ctx: CGContext, _ f: Fish, eye: Bool) {
    ctx.saveGState()
    ctx.concatenate(fishTransform(f))
    ctx.setAlpha(f.alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.saveGState()
    ctx.addPath(fishPath())
    ctx.clip()
    ctx.drawLinearGradient(
        gradient([Stop(at: 0, hex: bodyTail), Stop(at: 1, hex: bodyNose)]),
        start: CGPoint(x: 0, y: 25), end: CGPoint(x: 100, y: 25), options: [])
    ctx.restoreGState()
    if eye {
        ctx.setFillColor(color(eyeRing))
        ctx.fillEllipse(in: CGRect(x: eyeCenter.x - 6, y: eyeCenter.y - 6, width: 12, height: 12))
        ctx.setFillColor(color(eyeLight))
        ctx.fillEllipse(in: CGRect(x: eyeCenter.x - 2, y: eyeCenter.y - 3.5, width: 6, height: 6))
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
}

/// Soft light around a fish: the silhouette drawn with a wide zero-offset shadow.
func drawGlow(_ ctx: CGContext, _ f: Fish, strength: CGFloat, pixelScale: CGFloat) {
    ctx.saveGState()
    // Shadow blur is in device pixels, so scale it with the output size.
    ctx.setShadow(offset: .zero, blur: f.length * 0.22 * pixelScale, color: color(glowColor, 0.9 * strength))
    ctx.concatenate(fishTransform(f))
    ctx.addPath(fishPath())
    ctx.setFillColor(color(glowColor, 0.55 * strength))
    ctx.fillPath()
    ctx.restoreGState()
}

/// Draws in the y-down 1024 canvas. `pixels` is the output size, used to drop detail when small.
func drawIcon(_ ctx: CGContext, parts: Parts, pixels: Int, pixelScale: CGFloat, clipToBody: Bool) {
    let shape = CGPath(roundedRect: bodyRect, cornerWidth: bodyRadius, cornerHeight: bodyRadius, transform: nil)
    if clipToBody {
        // Baked drop shadow under the body, as on Apple's flat icons.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: 10 * pixelScale), blur: 24 * pixelScale, color: color(0x000000, 0.35))
        ctx.addPath(shape)
        ctx.setFillColor(color(abyss[1].hex))
        ctx.fillPath()
        ctx.restoreGState()
        ctx.addPath(shape)
        ctx.clip()
    }
    if parts.contains(.background) {
        ctx.drawLinearGradient(
            gradient(abyss), start: CGPoint(x: 0, y: bodyRect.minY), end: CGPoint(x: 0, y: bodyRect.maxY), options: [])
    }
    let visibleSchool = school.filter { pixels >= $0.minPixels }.map(\.fish)
    // At tiny sizes the lead fish grows a little so it still reads as a fish.
    var leader = lead
    if pixels <= 32 { leader.length *= 1.15 }
    if parts.contains(.glow) {
        for f in visibleSchool { drawGlow(ctx, f, strength: f.alpha, pixelScale: pixelScale) }
        drawGlow(ctx, leader, strength: 1, pixelScale: pixelScale)
    }
    if parts.contains(.school) {
        for f in visibleSchool { drawFish(ctx, f, eye: false) }
    }
    if parts.contains(.lead) {
        drawFish(ctx, leader, eye: pixels >= 32)
    }
}

// MARK: - Rendering

func render(px: Int, parts: Parts = .all, clipToBody: Bool = true, transform: CGAffineTransform = .identity) -> CGImage {
    let ctx = CGContext(
        data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    let s = CGFloat(px) / canvas
    // Flip to y-down so the coordinates match the SVG.
    ctx.translateBy(x: 0, y: CGFloat(px))
    ctx.scaleBy(x: s, y: -s)
    ctx.concatenate(transform)
    drawIcon(ctx, parts: parts, pixels: px, pixelScale: s * transform.a, clipToBody: clipToBody)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 72, kCGImagePropertyDPIHeight: 72] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(url.path)") }
}

func run(_ tool: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = args
    try! p.run()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { fatalError("\(tool) \(args) failed") }
}

func writeJSON(_ object: Any, to url: URL) {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    try! data.write(to: url)
}

// 1. Flat .iconset + .icns
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    writePNG(render(px: base), to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    writePNG(render(px: base * 2), to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
run("/usr/bin/iconutil", ["-c", "icns", iconset.path, "-o", assets.appendingPathComponent("AppIcon.icns").path])
writePNG(render(px: 1024), to: assets.appendingPathComponent("icon-1024.png"))

// 2. Icon Composer bundle (layered). The system supplies the squircle mask, glass,
// highlights and shadow, so layers are bare artwork on a transparent canvas, scaled
// so the body fills the full-bleed shape.
try? fm.removeItem(at: iconBundle)
let layerDir = iconBundle.appendingPathComponent("Assets")
try! fm.createDirectory(at: layerDir, withIntermediateDirectories: true)
let fullBleed = CGAffineTransform(translationX: 512, y: 512)
    .scaledBy(x: canvas / bodyRect.width, y: canvas / bodyRect.width)
    .translatedBy(x: -512, y: -512)
for (name, parts) in [("glow", Parts.glow), ("school", .school), ("lead", .lead)] {
    writePNG(
        render(px: 1024, parts: parts, clipToBody: false, transform: fullBleed),
        to: layerDir.appendingPathComponent("\(name).png"))
}

func srgb(_ hex: UInt32) -> String {
    let c = NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
        blue: CGFloat(hex & 0xff) / 255, alpha: 1
    ).usingColorSpace(.extendedSRGB)!
    return String(format: "extended-srgb:%.5f,%.5f,%.5f,1.00000", c.redComponent, c.greenComponent, c.blueComponent)
}

func layer(_ name: String, glass: Bool) -> [String: Any] {
    [
        "image-name": "\(name).png", "name": name, "glass": glass, "blend-mode": "normal", "hidden": false,
        "position": ["scale": 1, "translation-in-points": [0, 0]],
    ]
}

func group(_ layers: [[String: Any]], shadow: String, opacity: Double, specular: Bool) -> [String: Any] {
    [
        "layers": layers,
        "shadow": ["kind": shadow, "opacity": opacity],
        "specular": specular,
        "translucency": ["enabled": false, "value": 0.5],
    ]
}

func fill(_ stops: [Stop]) -> [String: Any] {
    [
        "linear-gradient": [srgb(stops.first!.hex), srgb(stops.last!.hex)],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ]
}

writeJSON(
    [
        "fill-specializations": [
            ["value": fill(abyss)],
            ["appearance": "dark", "value": fill(abyssDark)],
        ],
        // Front to back: lead fish, school, glow.
        "groups": [
            group([layer("lead", glass: true)], shadow: "layer-color", opacity: 0.5, specular: true),
            group([layer("school", glass: false)], shadow: "none", opacity: 0, specular: false),
            group([layer("glow", glass: false)], shadow: "none", opacity: 0, specular: false),
        ],
        "supported-platforms": ["squares": ["macOS"]],
    ] as [String: Any], to: iconBundle.appendingPathComponent("icon.json"))

// Accent colour catalog (NSAccentColorName = AccentColor in Info.plist).
try? fm.removeItem(at: colorCatalog)
let accentSet = colorCatalog.appendingPathComponent("AccentColor.colorset")
try! fm.createDirectory(at: accentSet, withIntermediateDirectories: true)
writeJSON(["info": ["author": "xcode", "version": 1]], to: colorCatalog.appendingPathComponent("Contents.json"))
func colorEntry(_ hex: UInt32, dark: Bool) -> [String: Any] {
    var entry: [String: Any] = [
        "idiom": "universal",
        "color": [
            "color-space": "srgb",
            "components": [
                "red": String(format: "0x%02X", (hex >> 16) & 0xff), "green": String(format: "0x%02X", (hex >> 8) & 0xff),
                "blue": String(format: "0x%02X", hex & 0xff), "alpha": "1.000",
            ],
        ],
    ]
    if dark { entry["appearances"] = [["appearance": "luminosity", "value": "dark"]] }
    return entry
}
writeJSON(
    [
        "colors": [colorEntry(accentLight, dark: false), colorEntry(accentDark, dark: true)],
        "info": ["author": "xcode", "version": 1],
    ] as [String: Any], to: accentSet.appendingPathComponent("Contents.json"))

// Compile both to assets/Assets.car (layered icon with light, dark and tinted renditions, read
// via CFBundleIconName; plus the accent colour). actool also emits a flat AppIcon.icns, which we
// discard in favour of ours.
let carTmp = fm.temporaryDirectory.appendingPathComponent("lanternfish-actool-\(getpid())")
try? fm.removeItem(at: carTmp)
try! fm.createDirectory(at: carTmp, withIntermediateDirectories: true)
run(
    "/usr/bin/xcrun",
    [
        "actool", iconBundle.path, colorCatalog.path, "--compile", carTmp.path, "--platform", "macosx",
        "--minimum-deployment-target", "27.0", "--app-icon", "AppIcon", "--accent-color", "AccentColor",
        "--output-partial-info-plist", carTmp.appendingPathComponent("partial.plist").path,
        "--errors", "--warnings", "--output-format", "human-readable-text",
    ])
let car = assets.appendingPathComponent("Assets.car")
try? fm.removeItem(at: car)
try! fm.copyItem(at: carTmp.appendingPathComponent("Assets.car"), to: car)
try? fm.removeItem(at: carTmp)

// 3. SVG (README).
func hex(_ c: UInt32) -> String { String(format: "#%06x", c) }
func svgTransform(_ f: Fish) -> String {
    "translate(\(f.x) \(f.y)) rotate(\(f.angle)) translate(\(-f.length / 2) \(-f.length / 4)) scale(\(f.length / 100))"
}
func svgFish(_ f: Fish, eye: Bool) -> String {
    var lines = [
        "    <g transform=\"\(svgTransform(f))\" opacity=\"\(f.alpha)\">",
        "      <path d=\"\(fishSVGPath)\" fill=\"url(#fish)\"/>",
    ]
    if eye {
        lines.append("      <circle cx=\"\(eyeCenter.x)\" cy=\"\(eyeCenter.y)\" r=\"6\" fill=\"\(hex(eyeRing))\"/>")
        lines.append("      <circle cx=\"\(eyeCenter.x + 1)\" cy=\"\(eyeCenter.y - 0.5)\" r=\"3\" fill=\"\(hex(eyeLight))\"/>")
    }
    lines.append("    </g>")
    return lines.joined(separator: "\n")
}
func svgGlow(_ f: Fish) -> String {
    "      <path d=\"\(fishSVGPath)\" transform=\"\(svgTransform(f))\" fill=\"\(hex(glowColor))\" opacity=\"\(f.alpha)\"/>"
}
let svgStops = abyss.map { "      <stop offset=\"\($0.at)\" stop-color=\"\(hex($0.hex))\"/>" }
let svg = (
    [
        "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 1024 1024\" width=\"1024\" height=\"1024\">",
        "  <defs>",
        "    <linearGradient id=\"abyss\" x1=\"0\" y1=\"\(bodyRect.minY)\" x2=\"0\" y2=\"\(bodyRect.maxY)\" gradientUnits=\"userSpaceOnUse\">",
    ] + svgStops + [
        "    </linearGradient>",
        "    <linearGradient id=\"fish\" x1=\"0\" y1=\"0\" x2=\"1\" y2=\"0\">",
        "      <stop offset=\"0\" stop-color=\"\(hex(bodyTail))\"/>",
        "      <stop offset=\"1\" stop-color=\"\(hex(bodyNose))\"/>",
        "    </linearGradient>",
        "    <filter id=\"glow\" x=\"-50%\" y=\"-50%\" width=\"200%\" height=\"200%\"><feGaussianBlur stdDeviation=\"22\"/></filter>",
        "    <clipPath id=\"body\"><rect x=\"\(bodyRect.minX)\" y=\"\(bodyRect.minY)\" width=\"\(bodyRect.width)\" height=\"\(bodyRect.height)\" rx=\"\(bodyRadius)\"/></clipPath>",
        "  </defs>",
        "  <g clip-path=\"url(#body)\">",
        "    <rect width=\"1024\" height=\"1024\" fill=\"url(#abyss)\"/>",
        "    <g filter=\"url(#glow)\" opacity=\"0.8\">",
    ] + school.map { svgGlow($0.fish) } + [svgGlow(lead), "    </g>"]
        + school.map { svgFish($0.fish, eye: false) } + [svgFish(lead, eye: true), "  </g>", "</svg>", ""]
).joined(separator: "\n")
try! svg.write(to: assets.appendingPathComponent("icon.svg"), atomically: true, encoding: .utf8)
print("Wrote icon assets to \(assets.path)")
