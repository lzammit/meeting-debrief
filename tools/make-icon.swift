#!/usr/bin/swift
// Generates the app icon master PNG (1024x1024).
// Usage: swift tools/make-icon.swift <output.png>
import AppKit

let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!
rep.size = NSSize(width: 1024, height: 1024)

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// --- Rounded-square background with blue gradient ---
let bgRect = CGRect(x: 100, y: 100, width: 824, height: 824)
let bgPath = NSBezierPath(roundedRect: bgRect, xRadius: 186, yRadius: 186)

NSGraphicsContext.saveGraphicsState()
bgPath.setClip()
NSGradient(colors: [
    NSColor(red: 0.44, green: 0.48, blue: 0.99, alpha: 1),
    NSColor(red: 0.18, green: 0.15, blue: 0.72, alpha: 1),
])!.draw(in: bgRect, angle: -90)
// Soft highlight across the top half
NSGradient(colors: [
    NSColor(white: 1, alpha: 0.22),
    NSColor(white: 1, alpha: 0.0),
])!.draw(in: CGRect(x: 100, y: 512, width: 824, height: 412), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// --- Calendar page (white, drop shadow) ---
let page = CGRect(x: 262, y: 230, width: 500, height: 460)
let pagePath = NSBezierPath(roundedRect: page, xRadius: 56, yRadius: 56)

NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
shadow.shadowOffset = NSSize(width: 0, height: -14)
shadow.shadowBlurRadius = 30
shadow.set()
NSColor.white.setFill()
pagePath.fill()
NSGraphicsContext.restoreGraphicsState()

// --- Header band (deep navy), clipped to the page's rounded corners ---
NSGraphicsContext.saveGraphicsState()
pagePath.setClip()
NSColor(red: 0.12, green: 0.11, blue: 0.42, alpha: 1).setFill()
NSBezierPath(rect: CGRect(x: 262, y: 566, width: 500, height: 124)).fill()
NSGraphicsContext.restoreGraphicsState()

// --- Binder rings piercing the header ---
for centerX in [402.0, 622.0] {
    let ring = NSBezierPath(
        roundedRect: CGRect(x: centerX - 19, y: 645, width: 38, height: 112),
        xRadius: 19, yRadius: 19
    )
    NSGraphicsContext.saveGraphicsState()
    let ringShadow = NSShadow()
    ringShadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    ringShadow.shadowOffset = NSSize(width: 0, height: -6)
    ringShadow.shadowBlurRadius = 10
    ringShadow.set()
    NSColor(red: 0.85, green: 0.89, blue: 0.96, alpha: 1).setFill()
    ring.fill()
    NSGraphicsContext.restoreGraphicsState()
}

// --- Brain (SF Symbols glyph) with an indigo-violet gradient, centered on the page ---
let symbolConfig = NSImage.SymbolConfiguration(pointSize: 300, weight: .bold)
let brain = NSImage(systemSymbolName: "brain", accessibilityDescription: nil)!
    .withSymbolConfiguration(symbolConfig)!

let maxBrainSize = CGSize(width: 360, height: 280)
let scale = min(maxBrainSize.width / brain.size.width, maxBrainSize.height / brain.size.height)
let brainSize = CGSize(width: brain.size.width * scale, height: brain.size.height * scale)
let brainRect = CGRect(
    x: 512 - brainSize.width / 2,
    y: 396 - brainSize.height / 2,
    width: brainSize.width, height: brainSize.height
)

var proposedRect = CGRect(origin: .zero, size: brain.size)
let brainCG = brain.cgImage(forProposedRect: &proposedRect, context: nil, hints: nil)!

let cgCtx = NSGraphicsContext.current!.cgContext
cgCtx.saveGState()
cgCtx.clip(to: brainRect, mask: brainCG)
NSGradient(colors: [
    NSColor(red: 0.62, green: 0.47, blue: 0.98, alpha: 1),
    NSColor(red: 0.31, green: 0.20, blue: 0.82, alpha: 1),
])!.draw(in: brainRect, angle: -90)
cgCtx.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: outputPath))
print("Wrote \(outputPath)")
