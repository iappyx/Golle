#!/bin/bash
# Draws the app icon and builds Resources/AppIcon.icns. Rerun after changing the design below.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
SET="$WORK/Golle.iconset"
mkdir -p "$SET"

cat > "$WORK/icon.swift" <<'SWIFT'
import AppKit

/// A rounded square with a warm gradient and a white card: a record, with a header row and fields.
func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons leave a margin; 1024pt art sits in about 824pt.
    let inset = size * 0.098
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    let top = NSColor(calibratedRed: 1.00, green: 0.66, blue: 0.25, alpha: 1)
    let bottom = NSColor(calibratedRed: 0.93, green: 0.36, blue: 0.16, alpha: 1)
    NSGradient(starting: bottom, ending: top)!.draw(in: shape, angle: 90)

    // The card.
    let card = rect.insetBy(dx: rect.width * 0.17, dy: rect.height * 0.19)
    let cardShape = NSBezierPath(roundedRect: card, xRadius: card.width * 0.07, yRadius: card.width * 0.07)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.012)
    shadow.shadowBlurRadius = size * 0.03
    shadow.set()
    NSColor.white.setFill()
    cardShape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Header band and field rows: a label stub and a longer value bar on each row.
    let accent = NSColor(calibratedRed: 0.93, green: 0.42, blue: 0.16, alpha: 1)
    let header = NSRect(x: card.minX, y: card.maxY - card.height * 0.24, width: card.width, height: card.height * 0.24)
    NSGraphicsContext.saveGraphicsState()
    cardShape.addClip()
    accent.withAlphaComponent(0.9).setFill()
    header.fill()
    NSGraphicsContext.restoreGraphicsState()

    let rowHeight = card.height * 0.085
    let gap = (header.minY - card.minY - rowHeight * 4) / 5
    for row in 0..<4 {
        let y = header.minY - gap * CGFloat(row + 1) - rowHeight * CGFloat(row + 1)
        let label = NSRect(x: card.minX + card.width * 0.1, y: y, width: card.width * 0.2, height: rowHeight)
        let value = NSRect(x: label.maxX + card.width * 0.06, y: y, width: card.width * (row % 2 == 0 ? 0.54 : 0.38), height: rowHeight)
        NSColor(white: 0.78, alpha: 1).setFill()
        NSBezierPath(roundedRect: label, xRadius: rowHeight / 2, yRadius: rowHeight / 2).fill()
        NSColor(white: 0.55, alpha: 1).setFill()
        NSBezierPath(roundedRect: value, xRadius: rowHeight / 2, yRadius: rowHeight / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let output = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = drawIcon(size: CGFloat(size))
    let data = rep.representation(using: .png, properties: [:])!
    let base = size <= 512 ? "icon_\(size)x\(size).png" : "icon_512x512@2x.png"
    try data.write(to: URL(fileURLWithPath: "\(output)/\(base)"))
    if size >= 32, size <= 512 {
        try data.write(to: URL(fileURLWithPath: "\(output)/icon_\(size / 2)x\(size / 2)@2x.png"))
    }
}
SWIFT

swift "$WORK/icon.swift" "$SET"
iconutil --convert icns "$SET" --output Resources/AppIcon.icns
echo "wrote Resources/AppIcon.icns"
