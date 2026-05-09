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

func renderIcon(pixels size: Int) throws -> NSBitmapImageRep {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create bitmap"])
    }
    bitmap.size = NSSize(width: size, height: size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    defer { NSGraphicsContext.restoreGraphicsState() }

    guard let context = NSGraphicsContext.current?.cgContext else { return bitmap }
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
        NSColor(srgbRed: 0.06, green: 0.12, blue: 0.14, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.15, green: 0.20, blue: 0.20, alpha: 1.0).cgColor
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

    drawMascotIcon(in: rect, size: CGFloat(size))

    return bitmap
}

func drawMascotIcon(in rect: NSRect, size: CGFloat) {
    let cellSize = max(1, floor(size / 23))
    let rows = mascotRows()
    let spriteWidth = CGFloat(rows.map(\.count).max() ?? 0) * cellSize
    let spriteHeight = CGFloat(rows.count) * cellSize
    let origin = NSPoint(
        x: floor(rect.midX - spriteWidth / 2),
        y: floor(rect.midY - spriteHeight / 2 - size * 0.01)
    )

    let context = NSGraphicsContext.current
    let previousAntialiasing = context?.shouldAntialias

    context?.shouldAntialias = true
    NSColor(calibratedWhite: 0.0, alpha: 0.24).setFill()
    let shadowRect = NSRect(
        x: origin.x + cellSize * 3,
        y: origin.y - cellSize * 0.9,
        width: spriteWidth - cellSize * 6,
        height: cellSize * 1.7
    )
    NSBezierPath(ovalIn: shadowRect).fill()

    context?.shouldAntialias = false
    drawMascotTail(origin: origin, cellSize: cellSize)
    drawMascotRows(rows, origin: origin, cellSize: cellSize)

    if let previousAntialiasing {
        context?.shouldAntialias = previousAntialiasing
    }
}

func mascotRows() -> [String] {
    [
        "................",
        "..WG........GW..",
        ".GWWW......WWWG.",
        ".GWWWWWWWWWWWWG.",
        "GWWWWWWWWWWWWWWG",
        "WWWWKKWWWWKKWWWW",
        "WWWWKKWWWWKKWWWW",
        "GWWWWWWPWWWWWWWG",
        "WWGWWWWWWWWWWGWW",
        ".GWWWWWWWWWWWWG.",
        "...WW......WW...",
        "................"
    ]
}

func drawMascotRows(_ rows: [String], origin: NSPoint, cellSize: CGFloat) {
    for (rowIndex, row) in rows.enumerated() {
        for (columnIndex, pixel) in row.enumerated() {
            guard let color = mascotColor(for: pixel) else { continue }
            color.setFill()
            let rect = NSRect(
                x: origin.x + CGFloat(columnIndex) * cellSize,
                y: origin.y + CGFloat(rows.count - rowIndex - 1) * cellSize,
                width: cellSize,
                height: cellSize
            )
            NSBezierPath(rect: rect).fill()
        }
    }
}

func drawMascotTail(origin: NSPoint, cellSize: CGFloat) {
    let cells = [(7, 9), (7, 10), (8, 11), (9, 12), (10, 12)]
    let tailColor = NSColor(srgbRed: 0.93, green: 0.94, blue: 0.90, alpha: 1.0)
    let tailShade = NSColor(srgbRed: 0.68, green: 0.72, blue: 0.73, alpha: 1.0)
    for (index, cell) in cells.enumerated() {
        (index == cells.count - 1 ? tailShade : tailColor).setFill()
        let rect = NSRect(
            x: origin.x + CGFloat(cell.0) * cellSize,
            y: origin.y + CGFloat(cell.1) * cellSize,
            width: cellSize,
            height: cellSize
        )
        NSBezierPath(rect: rect).fill()
    }
}

func mascotColor(for pixel: Character) -> NSColor? {
    switch pixel {
    case "W":
        return NSColor(srgbRed: 0.95, green: 0.96, blue: 0.92, alpha: 1)
    case "G":
        return NSColor(srgbRed: 0.70, green: 0.75, blue: 0.76, alpha: 1)
    case "K":
        return NSColor(srgbRed: 0.07, green: 0.09, blue: 0.12, alpha: 1)
    case "P":
        return NSColor(srgbRed: 0.92, green: 0.32, blue: 0.48, alpha: 1)
    default:
        return nil
    }
}

func writePNG(_ bitmap: NSBitmapImageRep, to url: URL) throws {
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url)
}

for variant in variants {
    let image = try renderIcon(pixels: variant.pixels)
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
