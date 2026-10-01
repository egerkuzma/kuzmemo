#!/usr/bin/env swift
// Draws the Kuzmemo app icon with Core Graphics and writes:
//   Resources/AppIcon.icns      the icon of the daily app
//   Resources/AppIconDev.icns   the same drawing in grey, so the automation build is easy to tell apart
//   Resources/AppIcon.icon, AppIconDev.icon   the same two as layered Icon Composer documents (macOS 26 notifications)
//   docs/images/icon.png        1024 px picture for the README
//
// The idea: a calendar page (the app's own calendar) whose body is a voice waveform (you talk to it). A macOS icon is
// a rounded "squircle" 824 px wide on a 1024 px canvas. Every size is drawn from scratch, not scaled, and the small
// ones use fewer, thicker bars so that the waveform survives at 16 px.
//
//   swift scripts/make_icon.swift            (run from the repository root)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Palette {
    var backgroundTop: CGColor
    var backgroundBottom: CGColor
    var headerLeft: CGColor
    var headerRight: CGColor
    var barTop: CGColor
    var barBottom: CGColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
    )
}

let daily = Palette(
    backgroundTop: rgb(0x7280FF), backgroundBottom: rgb(0x2E2597),
    headerLeft: rgb(0xFF9A5C), headerRight: rgb(0xFF4E7D),
    barTop: rgb(0x6A78FF), barBottom: rgb(0x2E2597)
)
let development = Palette(
    backgroundTop: rgb(0xA3A9B5), backgroundBottom: rgb(0x474C58),
    headerLeft: rgb(0xFFC857), headerRight: rgb(0xF29E1F),
    barTop: rgb(0x8A91A1), barBottom: rgb(0x474C58)
)

/// A superellipse (exponent 8) is close to the continuous corner of Apple's icon shape: long straight-ish edges, tight corners.
func squircle(center: CGPoint, half: CGFloat, exponent n: CGFloat = 8) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for i in 0 ... steps {
        let t = CGFloat(i) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let point = CGPoint(
            x: center.x + half * (c < 0 ? -1 : 1) * pow(abs(c), 2 / n), y: center.y + half * (s < 0 ? -1 : 1) * pow(abs(s), 2 / n)
        )
        if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

/// Draws the icon in a 1024 x 1024 design space.
func draw(_ ctx: CGContext, palette: Palette, simple: Bool) {
    let center = CGPoint(x: 512, y: 512)

    // The squircle with its shadow.
    let shape = squircle(center: center, half: 412)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: rgb(0x000000, 0.35))
    ctx.addPath(shape)
    ctx.setFillColor(palette.backgroundBottom)
    ctx.fillPath()
    ctx.restoreGState()

    // Its background: a vertical gradient with a soft light from above.
    ctx.saveGState()
    ctx.addPath(shape)
    ctx.clip()
    ctx.drawLinearGradient(gradient([palette.backgroundTop, palette.backgroundBottom]), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.drawRadialGradient(
        gradient([rgb(0xFFFFFF, 0.28), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: 512, y: 930), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 930), endRadius: 620, options: []
    )
    ctx.restoreGState()

    // The calendar page.
    let card = CGRect(x: 226, y: 222, width: 572, height: 592)
    let cardPath = roundedRect(card, radius: 82)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -20), blur: 40, color: rgb(0x000000, 0.32))
    ctx.addPath(cardPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // Its header band.
    let headerHeight: CGFloat = 158
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let header = CGRect(x: card.minX, y: card.maxY - headerHeight, width: card.width, height: headerHeight)
    ctx.clip(to: header)
    ctx.drawLinearGradient(gradient([palette.headerLeft, palette.headerRight]), start: CGPoint(x: header.minX, y: header.midY), end: CGPoint(x: header.maxX, y: header.midY), options: [])
    ctx.restoreGState()

    // The two binding tabs across the top edge.
    let tabWidth: CGFloat = 54, tabHeight: CGFloat = 112
    for x in [card.minX + 132, card.maxX - 132 - tabWidth] {
        let tab = CGRect(x: x, y: card.maxY - 70, width: tabWidth, height: tabHeight)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: rgb(0x000000, 0.28))
        ctx.addPath(roundedRect(tab, radius: tabWidth / 2))
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath()
        ctx.restoreGState()
    }

    // The voice waveform in the body of the page.
    let bodyMidY = card.minY + (card.height - headerHeight) / 2
    let heights: [CGFloat] = simple ? [130, 262, 372, 262, 130] : [98, 192, 292, 374, 292, 192, 98]
    let width: CGFloat = simple ? 66 : 46
    let gap: CGFloat = simple ? 36 : 28
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    var x = card.midX - total / 2
    for height in heights {
        let bar = CGRect(x: x, y: bodyMidY - height / 2, width: width, height: height)
        ctx.saveGState()
        ctx.addPath(roundedRect(bar, radius: width / 2))
        ctx.clip()
        ctx.drawLinearGradient(gradient([palette.barTop, palette.barBottom]), start: CGPoint(x: bar.midX, y: bar.maxY), end: CGPoint(x: bar.midX, y: bar.minY), options: [])
        ctx.restoreGState()
        x += width + gap
    }
}

func render(size: Int, palette: Palette) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    draw(ctx, palette: palette, simple: size <= 64)
    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("could not write \(url.path)") }
}

/// Builds `<name>.icns` from an iconset drawn size by size.
func makeICNS(named name: String, palette: Palette, in resources: URL) {
    let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString).iconset")
    defer { try? FileManager.default.removeItem(at: iconset) }
    let files: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
        ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (file, size) in files { writePNG(render(size: size, palette: palette), to: iconset.appendingPathComponent("\(file).png")) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("\(name).icns").path]
    try! process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fatalError("iconutil failed for \(name)") }
}

// MARK: - The layered icon of macOS 26 (an Icon Composer document, compiled into Assets.car by actool)
//
// macOS 26 takes the icon of a notification banner from the new layered format; an .icns file alone showed a blank white
// square there. The system makes the squircle, the shadow and the light itself, so the layers are the page and the
// waveform alone, on transparent 1024 px canvases, and the background is a fill the system turns into a gradient.

func renderLayer(_ body: (CGContext) -> Void) -> CGImage {
    let ctx = CGContext(
        data: nil, width: 1024, height: 1024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    ctx.interpolationQuality = .high
    body(ctx)
    return ctx.makeImage()!
}

/// The calendar page: white body, coloured header band, the two binding tabs.
func drawPageLayer(_ ctx: CGContext, palette: Palette) {
    let card = CGRect(x: 226, y: 222, width: 572, height: 592)
    let cardPath = roundedRect(card, radius: 82)
    ctx.addPath(cardPath)
    ctx.setFillColor(rgb(0xFFFFFF))
    ctx.fillPath()
    ctx.saveGState()
    ctx.addPath(cardPath)
    ctx.clip()
    let header = CGRect(x: card.minX, y: card.maxY - 158, width: card.width, height: 158)
    ctx.clip(to: header)
    ctx.drawLinearGradient(gradient([palette.headerLeft, palette.headerRight]), start: CGPoint(x: header.minX, y: header.midY), end: CGPoint(x: header.maxX, y: header.midY), options: [])
    ctx.restoreGState()
    let tabWidth: CGFloat = 54, tabHeight: CGFloat = 112
    for x in [card.minX + 132, card.maxX - 132 - tabWidth] {
        ctx.addPath(roundedRect(CGRect(x: x, y: card.maxY - 70, width: tabWidth, height: tabHeight), radius: tabWidth / 2))
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.fillPath()
    }
}

/// The voice waveform in the body of the page.
func drawWaveLayer(_ ctx: CGContext, palette: Palette) {
    let card = CGRect(x: 226, y: 222, width: 572, height: 592)
    let bodyMidY = card.minY + (card.height - 158) / 2
    let heights: [CGFloat] = [98, 192, 292, 374, 292, 192, 98]
    let width: CGFloat = 46, gap: CGFloat = 28
    let total = CGFloat(heights.count) * width + CGFloat(heights.count - 1) * gap
    var x = card.midX - total / 2
    for height in heights {
        let bar = CGRect(x: x, y: bodyMidY - height / 2, width: width, height: height)
        ctx.saveGState()
        ctx.addPath(roundedRect(bar, radius: width / 2))
        ctx.clip()
        ctx.drawLinearGradient(gradient([palette.barTop, palette.barBottom]), start: CGPoint(x: bar.midX, y: bar.maxY), end: CGPoint(x: bar.midX, y: bar.minY), options: [])
        ctx.restoreGState()
        x += width + gap
    }
}

/// Writes `<name>.icon` (icon.json and the two layer images). `fill` is the colour the system turns into the background.
func makeLayeredIcon(named name: String, palette: Palette, fill: (CGFloat, CGFloat, CGFloat), in resources: URL) {
    let folder = resources.appendingPathComponent("\(name).icon")
    try? FileManager.default.removeItem(at: folder)
    writePNG(renderLayer { drawPageLayer($0, palette: palette) }, to: folder.appendingPathComponent("Assets/page.png"))
    writePNG(renderLayer { drawWaveLayer($0, palette: palette) }, to: folder.appendingPathComponent("Assets/waveform.png"))
    let json = """
    {
      "fill" : { "automatic-gradient" : "display-p3:\(fill.0),\(fill.1),\(fill.2),1.00000" },
      "groups" : [
        {
          "layers" : [
            { "image-name" : "waveform.png", "name" : "waveform" },
            { "image-name" : "page.png", "name" : "page" }
          ],
          "shadow" : { "kind" : "neutral", "opacity" : 0.5 },
          "translucency" : { "enabled" : false, "value" : 0.5 }
        }
      ],
      "supported-platforms" : { "squares" : "shared" }
    }
    """
    try! json.write(to: folder.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resources = root.appendingPathComponent("Resources")
try? FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
makeICNS(named: "AppIcon", palette: daily, in: resources)
makeICNS(named: "AppIconDev", palette: development, in: resources)
makeLayeredIcon(named: "AppIcon", palette: daily, fill: (0.31, 0.32, 0.80), in: resources)
makeLayeredIcon(named: "AppIconDev", palette: development, fill: (0.42, 0.44, 0.50), in: resources)
writePNG(render(size: 1024, palette: daily), to: root.appendingPathComponent("docs/images/icon.png"))
print("wrote Resources/AppIcon.icns, AppIcon.icon, AppIconDev.icns, AppIconDev.icon, docs/images/icon.png")
