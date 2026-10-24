import AppKit
import Foundation

/// Tests release the decoder explicitly; assertions never depend on a fast/slow disk.
final class ControlledDecoder: @unchecked Sendable {
    struct Snapshot {
        var previewStarts: Int
        var detailStarts: Int
        var activePreview: Int
        var activeDetail: Int
        var maximumPreview: Int
        var maximumDetail: Int
        var filenames: [String]
    }
    private let condition = NSCondition()
    private var blocked: Bool
    private var state = Snapshot(previewStarts: 0, detailStarts: 0, activePreview: 0, activeDetail: 0,
                                 maximumPreview: 0, maximumDetail: 0, filenames: [])
    private let onStart: (@Sendable (Snapshot) -> Void)?
    private let pixels: Int
    init(blocked: Bool = true, pixels: Int = 64, onStart: (@Sendable (Snapshot) -> Void)? = nil) {
        self.blocked = blocked; self.pixels = pixels; self.onStart = onStart
    }
    var snapshot: Snapshot { condition.lock(); defer { condition.unlock() }; return state }
    func releaseAll() { condition.lock(); blocked = false; condition.broadcast(); condition.unlock() }
    func decode(url: URL, maxPixel: Int, detail: Bool) throws -> NSImage {
        condition.lock()
        state.filenames.append(url.lastPathComponent)
        if detail {
            state.detailStarts += 1; state.activeDetail += 1; state.maximumDetail = max(state.maximumDetail, state.activeDetail)
        } else {
            state.previewStarts += 1; state.activePreview += 1; state.maximumPreview = max(state.maximumPreview, state.activePreview)
        }
        let started = state
        condition.unlock()
        onStart?(started)
        condition.lock()
        while blocked { condition.wait() }
        if detail { state.activeDetail -= 1 } else { state.activePreview -= 1 }
        condition.unlock()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: pixels * 4, bitsPerPixel: 32)!
        let image = NSImage(size: NSSize(width: pixels, height: pixels)); image.addRepresentation(bitmap)
        return image
    }
}
