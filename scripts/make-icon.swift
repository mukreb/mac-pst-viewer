// Renders the app icon (1024x1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let size = 1024.0
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

let inset = size * 0.1
let rect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let path = NSBezierPath(roundedRect: rect, xRadius: size * 0.18, yRadius: size * 0.18)
NSGradient(starting: NSColor(calibratedRed: 0.16, green: 0.47, blue: 0.95, alpha: 1),
           ending: NSColor(calibratedRed: 0.05, green: 0.26, blue: 0.66, alpha: 1))!.draw(in: path, angle: -90)

let config = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .regular)
    .applying(.init(paletteColors: [.white]))
if let symbol = NSImage(systemSymbolName: "tray.full.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let s = symbol.size
    symbol.draw(in: NSRect(x: (size - s.width) / 2, y: (size - s.height) / 2 + size * 0.02, width: s.width, height: s.height))
}
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
