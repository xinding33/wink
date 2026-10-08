import AppKit

let output = CommandLine.arguments[1]
let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString + ".iconset")
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let side = CGFloat(pixels)
        NSColor(calibratedRed: 0.10, green: 0.20, blue: 0.32, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: side * 0.05, y: side * 0.05, width: side * 0.9, height: side * 0.9), xRadius: side * 0.20, yRadius: side * 0.20).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: side * 0.56, weight: .medium)
            .applying(.init(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
            symbol.draw(in: NSRect(x: side * 0.20, y: side * 0.28, width: side * 0.60, height: side * 0.48))
        }
        NSColor(calibratedRed: 0.32, green: 0.91, blue: 0.70, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: side * 0.69, y: side * 0.20, width: side * 0.17, height: side * 0.17)).fill()
        image.unlockFocus()
        let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)" + (scale == 2 ? "@2x" : "") + ".png"
        try rep.representation(using: .png, properties: [:])!.write(to: folder.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", folder.path, "-o", output]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { exit(1) }
