#!/usr/bin/env swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Regenerate every AppIcon size from the same flat, resolution-independent artwork.
// Run from the repository root: swift -module-cache-path build/DerivedData/ModuleCache.noindex scripts/generate_app_icon.swift
let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let assets = repository.appendingPathComponent("tvbox/Assets.xcassets/AppIcon.appiconset")

struct IconCatalog: Decodable {
    struct Image: Decodable {
        let filename: String
        let idiom: String
        let size: String
        let scale: String?
    }
    let images: [Image]
}

let catalog = try JSONDecoder().decode(IconCatalog.self, from: Data(contentsOf: assets.appendingPathComponent("Contents.json")))
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

for icon in catalog.images {
    let points = Double(icon.size.components(separatedBy: "x")[0])!
    let scale = Double((icon.scale ?? "1x").dropLast())!
    let pixels = Int(points * scale)
    let isMac = icon.idiom == "mac"
    let alpha: CGImageAlphaInfo = isMac ? .premultipliedLast : .noneSkipLast
    let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                            bytesPerRow: pixels * 4, space: colorSpace,
                            bitmapInfo: alpha.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
    context.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    context.setAllowsAntialiasing(true)

    // iOS supplies its own corner mask; macOS uses an inset white tile with transparent corners.
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    if isMac {
        let tile = CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                          cornerWidth: 196, cornerHeight: 196, transform: nil)
        context.addPath(tile)
        context.fillPath()
        context.setStrokeColor(CGColor(gray: 0.90, alpha: 1))
        context.setLineWidth(2)
        context.addPath(tile)
        context.strokePath()
    } else {
        context.fill(CGRect(x: 0, y: 0, width: 1024, height: 1024))
    }

    // A single television outline and orange play mark stay legible at Dock and list sizes.
    context.setStrokeColor(CGColor(srgbRed: 0.14, green: 0.15, blue: 0.17, alpha: 1))
    context.setLineWidth(36)
    context.setLineCap(.round)
    context.addPath(CGPath(roundedRect: CGRect(x: 228, y: 368, width: 568, height: 376),
                           cornerWidth: 64, cornerHeight: 64, transform: nil))
    context.strokePath()
    context.move(to: CGPoint(x: 512, y: 350))
    context.addLine(to: CGPoint(x: 512, y: 288))
    context.move(to: CGPoint(x: 424, y: 288))
    context.addLine(to: CGPoint(x: 600, y: 288))
    context.strokePath()

    let play = CGMutablePath()
    play.move(to: CGPoint(x: 480, y: 648))
    play.addLine(to: CGPoint(x: 619, y: 568))
    play.addQuadCurve(to: CGPoint(x: 619, y: 544), control: CGPoint(x: 640, y: 556))
    play.addLine(to: CGPoint(x: 480, y: 464))
    play.addQuadCurve(to: CGPoint(x: 456, y: 478), control: CGPoint(x: 456, y: 450))
    play.addLine(to: CGPoint(x: 456, y: 634))
    play.addQuadCurve(to: CGPoint(x: 480, y: 648), control: CGPoint(x: 456, y: 662))
    play.closeSubpath()
    context.setFillColor(CGColor(srgbRed: 1, green: 0.53, blue: 0, alpha: 1))
    context.addPath(play)
    context.fillPath()

    let destination = CGImageDestinationCreateWithURL(assets.appendingPathComponent(icon.filename) as CFURL,
                                                     UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Could not write \(icon.filename)") }
    print("Generated \(icon.filename): \(pixels)×\(pixels)")
}
