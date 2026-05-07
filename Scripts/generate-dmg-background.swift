#!/usr/bin/env swift

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("Usage: generate-dmg-background.swift <output.png>\n".utf8))
    exit(2)
}

let outputURL = URL(fileURLWithPath: arguments[1])
let size = NSSize(width: 540, height: 380)

let image = NSImage(size: size)
image.lockFocus()

let backgroundRect = NSRect(origin: .zero, size: size)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.10, green: 0.12, blue: 0.22, alpha: 1.0),
    NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.55, alpha: 1.0)
])!
gradient.draw(in: backgroundRect, angle: 315)

let yakuFont = NSFont.systemFont(ofSize: 28, weight: .semibold)
let yakuAttributes: [NSAttributedString.Key: Any] = [
    .font: yakuFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.92),
    .kern: 1.5
]
let yakuText = "Yaku" as NSString
let yakuSize = yakuText.size(withAttributes: yakuAttributes)
yakuText.draw(
    at: NSPoint(x: (size.width - yakuSize.width) / 2, y: size.height - 64),
    withAttributes: yakuAttributes
)

let subtitleFont = NSFont.systemFont(ofSize: 13, weight: .regular)
let subtitleAttributes: [NSAttributedString.Key: Any] = [
    .font: subtitleFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.55)
]
let subtitle = "Drag Yaku into Applications" as NSString
let subtitleSize = subtitle.size(withAttributes: subtitleAttributes)
subtitle.draw(
    at: NSPoint(x: (size.width - subtitleSize.width) / 2, y: size.height - 92),
    withAttributes: subtitleAttributes
)

let arrowFont = NSFont.systemFont(ofSize: 72, weight: .ultraLight)
let arrowAttributes: [NSAttributedString.Key: Any] = [
    .font: arrowFont,
    .foregroundColor: NSColor.white.withAlphaComponent(0.20)
]
let arrow = "→" as NSString
let arrowSize = arrow.size(withAttributes: arrowAttributes)
arrow.draw(
    at: NSPoint(x: (size.width - arrowSize.width) / 2, y: 130),
    withAttributes: arrowAttributes
)

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("Failed to encode PNG\n".utf8))
    exit(1)
}

try png.write(to: outputURL)
print("Wrote \(outputURL.path)")
