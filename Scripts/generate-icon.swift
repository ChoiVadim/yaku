#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon.swift <output.icns>\n".utf8))
    exit(2)
}

let outputICNS = URL(fileURLWithPath: arguments[1])
let scriptDir = URL(fileURLWithPath: arguments[0]).deletingLastPathComponent()
let workDir = scriptDir.deletingLastPathComponent().appendingPathComponent(".build/icon-stage")
let iconset = workDir.appendingPathComponent("AppIcon.iconset")

try? FileManager.default.removeItem(at: workDir)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

struct Variant {
    let pixels: Int
    let filename: String
}

let variants: [Variant] = [
    .init(pixels: 16,   filename: "icon_16x16.png"),
    .init(pixels: 32,   filename: "icon_16x16@2x.png"),
    .init(pixels: 32,   filename: "icon_32x32.png"),
    .init(pixels: 64,   filename: "icon_32x32@2x.png"),
    .init(pixels: 128,  filename: "icon_128x128.png"),
    .init(pixels: 256,  filename: "icon_128x128@2x.png"),
    .init(pixels: 256,  filename: "icon_256x256.png"),
    .init(pixels: 512,  filename: "icon_256x256@2x.png"),
    .init(pixels: 512,  filename: "icon_512x512.png"),
    .init(pixels: 1024, filename: "icon_512x512@2x.png")
]

func renderIcon(pixels size: Int) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let context = NSGraphicsContext.current?.cgContext else { return image }
    let rect = NSRect(x: 0, y: 0, width: size, height: size)

    // Squircle-ish background with rounded corners (≈22.5% radius).
    let cornerRadius = CGFloat(size) * 0.225
    let backgroundPath = NSBezierPath(
        roundedRect: rect.insetBy(dx: 0, dy: 0),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    backgroundPath.addClip()

    let colors = [
        NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.22, alpha: 1.0).cgColor,
        NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.55, alpha: 1.0).cgColor
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: colors as CFArray,
        locations: [0.0, 1.0]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0, y: CGFloat(size)),
        end: CGPoint(x: CGFloat(size), y: 0),
        options: []
    )

    // Subtle inner highlight.
    let highlightPath = NSBezierPath(
        roundedRect: rect.insetBy(dx: CGFloat(size) * 0.04, dy: CGFloat(size) * 0.04),
        xRadius: cornerRadius * 0.92,
        yRadius: cornerRadius * 0.92
    )
    NSColor(calibratedWhite: 1.0, alpha: 0.05).setStroke()
    highlightPath.lineWidth = max(1, CGFloat(size) * 0.012)
    highlightPath.stroke()

    // The brand glyph: あ centered, semibold white.
    let fontSize = CGFloat(size) * 0.62
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: fontSize, weight: .semibold),
        .foregroundColor: NSColor.white,
        .paragraphStyle: paragraph
    ]
    let glyph = "あ" as NSString
    let glyphSize = glyph.size(withAttributes: attributes)
    let glyphRect = NSRect(
        x: 0,
        y: (CGFloat(size) - glyphSize.height) / 2 - CGFloat(size) * 0.03,
        width: CGFloat(size),
        height: glyphSize.height
    )
    glyph.draw(in: glyphRect, withAttributes: attributes)

    return image
}

func writePNG(_ image: NSImage, to url: URL) throws {
    guard let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url)
}

for variant in variants {
    let image = renderIcon(pixels: variant.pixels)
    let url = iconset.appendingPathComponent(variant.filename)
    try writePNG(image, to: url)
    print("Wrote \(variant.filename) (\(variant.pixels)px)")
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", "-o", outputICNS.path, iconset.path]
try process.run()
process.waitUntilExit()
guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed (status \(process.terminationStatus))\n".utf8))
    exit(process.terminationStatus)
}
print("Built \(outputICNS.path)")
