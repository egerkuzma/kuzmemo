#!/usr/bin/env swift
// Finishes raw screenshots for the README: rounded corners, a hairline edge, a soft drop shadow and a transparent margin,
// the way macOS itself shows a window. Reads a JSON list of jobs and writes the PNGs.
//
//   swift scripts/frame_screenshots.swift jobs.json
//   jobs.json: [{"input": "raw.png", "output": "docs/images/x.png", "radius": 48, "margin": 64}]
//
// `radius` and `margin` are in pixels of the input picture (0 radius leaves the corners as they are).
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Job: Decodable {
    var input: String
    var output: String
    var radius: Double
    var margin: Double
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let jobs = try JSONDecoder().decode([Job].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for job in jobs {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: job.input) as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { print("cannot read \(job.input)"); continue }
    let margin = Int(job.margin)
    let ctx = CGContext(
        data: nil, width: image.width + 2 * margin, height: image.height + 2 * margin, bitsPerComponent: 8, bytesPerRow: 0, space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    )!
    ctx.interpolationQuality = .high
    let rect = CGRect(x: margin, y: margin, width: image.width, height: image.height)
    let shape = CGPath(roundedRect: rect, cornerWidth: job.radius, cornerHeight: job.radius, transform: nil)

    // The picture and its shadow.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -job.margin * 0.16), blur: job.margin * 0.55, color: CGColor(gray: 0, alpha: 0.36))
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(shape)
    ctx.clip()
    ctx.draw(image, in: rect)
    ctx.endTransparencyLayer()
    ctx.restoreGState()

    // A hairline edge, so a light picture does not melt into a light page.
    if job.radius > 0 {
        ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerWidth: job.radius - 1, cornerHeight: job.radius - 1, transform: nil))
        ctx.setStrokeColor(CGColor(gray: 0.5, alpha: 0.28))
        ctx.setLineWidth(2)
        ctx.strokePath()
    }

    let url = URL(fileURLWithPath: job.output)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, ctx.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(job.output)") }
    print("wrote \(job.output)")
}
