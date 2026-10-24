import AppKit

// ictool exports the masked icon edge-to-edge. applicationIconImage expects a
// complete macOS icon canvas, including the space outside that mask. Measured
// on macOS 27: native Notes, Photos, Calculator and our compiled AppIcon all
// have a 824 px body centered in a 1024 px canvas (100 px on each side).
// Apply this only to runtime PNGs, never to the full-bleed .icon source layers.
let canvas = 1024
let inset = 100
let arguments = Array(CommandLine.arguments.dropFirst())
let checkOnly = arguments.first == "--check"
let paths = checkOnly ? Array(arguments.dropFirst()) : arguments
guard paths.count == 2 else {
    fputs("Usage: prepare-dock-icons.swift [--check] light.png dark.png\n", stderr)
    exit(1)
}

do {
    for path in paths {
        let url = URL(fileURLWithPath: path)
        guard let image = NSImage(contentsOf: url),
              let source = NSBitmapImageRep(data: try Data(contentsOf: url)),
              source.pixelsWide == canvas, source.pixelsHigh == canvas else {
            throw NSError(domain: "DockIcon", code: 1, userInfo: [NSLocalizedDescriptionKey: "Expected 1024×1024 PNG: \(path)"])
        }
        if !checkOnly {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: canvas, pixelsHigh: canvas,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            NSGraphicsContext.current?.imageInterpolation = .high
            NSColor.clear.setFill()
            NSRect(x: 0, y: 0, width: canvas, height: canvas).fill(using: .copy)
            image.draw(in: NSRect(x: inset, y: inset, width: canvas - 2 * inset, height: canvas - 2 * inset),
                       from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            try bitmap.representation(using: .png, properties: [:])!.write(to: url, options: .atomic)
        }

        let bitmap = NSBitmapImageRep(data: try Data(contentsOf: url))!
        var minX = canvas, minY = canvas, maxX = -1, maxY = -1
        for y in 0..<canvas {
            for x in 0..<canvas where bitmap.colorAt(x: x, y: y)!.alphaComponent >= 0.5 {
                minX = min(minX, x); minY = min(minY, y)
                maxX = max(maxX, x); maxY = max(maxY, y)
            }
        }
        guard abs(minX - inset) <= 1, abs(minY - inset) <= 1,
              abs(maxX + 1 - (canvas - inset)) <= 1,
              abs(maxY + 1 - (canvas - inset)) <= 1,
              bitmap.colorAt(x: 0, y: canvas / 2)!.alphaComponent == 0,
              bitmap.colorAt(x: canvas / 2, y: 0)!.alphaComponent == 0,
              bitmap.colorAt(x: canvas - 1, y: canvas / 2)!.alphaComponent == 0,
              bitmap.colorAt(x: canvas / 2, y: canvas - 1)!.alphaComponent == 0 else {
            throw NSError(domain: "DockIcon", code: 2, userInfo: [NSLocalizedDescriptionKey: "Incorrect Dock body bounds: \(path): \([minX, minY, maxX + 1, maxY + 1])"])
        }
        print("\(url.lastPathComponent): 1024×1024, body \([minX, minY, maxX + 1, maxY + 1])")
    }
} catch {
    fputs("Dock icon validation failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
