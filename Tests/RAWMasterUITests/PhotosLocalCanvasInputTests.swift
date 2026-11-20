import AppKit
import XCTest
@testable import RAWMasterImaging

final class PhotosLocalCanvasInputTests: XCTestCase {
    @MainActor func testOptionalHoverBridgeReportsExactViewportAndDoesNotReplacePointerOwner() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: .init(x: 0, y: 0, width: 400, height: 300))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 80, pixelsHigh: 40,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 320, bitsPerPixel: 32))
        bitmap.bitmapData!.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = NSImage(size: .init(width: 80, height: 40)); image.addRepresentation(bitmap)
        canvas.update(image: image, actualPixels: false, transform: .init()); canvas.frameID = UUID()
        canvas.setInteractionHandlers(pointer: nil, viewport: nil)
        canvas.updateTrackingAreas(); XCTAssertTrue(canvas.trackingAreas.isEmpty)
        var events: [ImageCanvasHoverEvent] = [], phases: [ImageCanvasPointerPhase] = []
        canvas.setInteractionHandlers(pointer: { phases.append($0.phase); return true }, viewport: nil, hover: { events.append($0) })
        canvas.updateTrackingAreas(); XCTAssertEqual(canvas.trackingAreas.count, 1)
        func event(_ type: NSEvent.EventType) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .init(x: 180, y: 150), modifierFlags: [.option],
                timestamp: 1, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 0))
        }
        canvas.mouseMoved(with: try event(.mouseMoved))
        let hover = try XCTUnwrap(events.last)
        XCTAssertEqual(hover.viewport.frameID, canvas.frameID)
        XCTAssertEqual(hover.viewport.imageRect, ImageViewportGeometry.imageRect(pixelSize: .init(width: 80, height: 40),
            viewport: canvas.bounds.size, transform: .init(), backingScale: hover.viewport.backingScale))
        XCTAssertNotNil(hover.locationInView); XCTAssertEqual(hover.modifiersRawValue, UInt64(NSEvent.ModifierFlags.option.rawValue))
        canvas.mouseDown(with: try event(.leftMouseDown))
        canvas.mouseMoved(with: try event(.mouseMoved)); canvas.mouseDragged(with: try event(.leftMouseDragged))
        XCTAssertEqual(phases, [.began, .changed])
        canvas.mouseExited(with: try event(.mouseMoved)); XCTAssertNil(events.last?.locationInView)
        canvas.clearInteractionHandlers(); XCTAssertEqual(phases, [.began, .changed, .cancelled])
        let count = events.count
        canvas.mouseMoved(with: try event(.mouseMoved)); XCTAssertEqual(events.count, count)
        canvas.updateTrackingAreas(); XCTAssertTrue(canvas.trackingAreas.isEmpty)
    }
}
