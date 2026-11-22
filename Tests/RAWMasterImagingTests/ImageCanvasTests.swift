import XCTest
import AppKit
@testable import RAWMasterImaging

private final class DrawObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [NSRect] = []
    var rects: [NSRect] { lock.lock(); defer { lock.unlock() }; return storage }
    func record(_ rect: NSRect) { lock.lock(); storage.append(rect); lock.unlock() }
}
private final class DrawObservedImage: NSImage, @unchecked Sendable {
    private let observation = DrawObservation()
    var drawnRects: [NSRect] { observation.rects }
    override func draw(in rect: NSRect, from source: NSRect, operation: NSCompositingOperation,
                       fraction: CGFloat, respectFlipped: Bool, hints: [NSImageRep.HintKey: Any]?) {
        observation.record(rect)
        super.draw(in: rect, from: source, operation: operation, fraction: fraction,
                   respectFlipped: respectFlipped, hints: hints)
    }
}

final class ImageCanvasTests: XCTestCase {
    @MainActor func testSharedCanvasRetainsSourceRasterAndMatchesAppKitAcrossZoomAndCoordinates() throws {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmap = PreviewSharedImageBridge.bitmapInfo.rawValue
        let source = try XCTUnwrap(CGContext(data:nil,width:127,height:79,bitsPerComponent:8,bytesPerRow:127*4,space:space,bitmapInfo:bitmap))
        for y in 0..<79 {
            for x in 0..<127 {
                source.setFillColor(red:CGFloat(x)/126,green:CGFloat(y)/78,blue:CGFloat(x % 11)/10,alpha:x < 50 ? 0.4 : 1)
                source.fill(CGRect(x:x,y:y,width:1,height:1))
            }
        }
        let raster = try XCTUnwrap(CGImage(width:127,height:79,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:127*4,
            space:space,bitmapInfo:PreviewSharedImageBridge.bitmapInfo,
            provider:CGDataProvider(data:Data(bytes:try XCTUnwrap(source.data),count:127*79*4) as CFData)!,
            decode:nil,shouldInterpolate:false,intent:.defaultIntent))
        let shared = PreviewSharedImageBridge.presentationImage(raster)
        let ordinary = NSImage(cgImage:raster,size:shared.size)
        XCTAssertTrue(PreviewSharedImageBridge.canvasRaster(for:shared) === raster)
        XCTAssertNil(PreviewSharedImageBridge.canvasRaster(for:ordinary))
        let canvas = ImageCanvas(frame:.init(x:0,y:0,width:93,height:67))
        func pixels(_ image:NSImage,scale:CGFloat,flipped:Bool,lowLatency:Bool) throws -> Data {
            canvas.update(image:image,actualPixels:false,transform:.init(scale:scale,centerX:0.43,centerY:0.56),
                          backgroundColor:.black,lowLatency:lowLatency)
            let context = try XCTUnwrap(CGContext(data:nil,width:93,height:67,bitsPerComponent:8,bytesPerRow:93*4,space:space,bitmapInfo:bitmap))
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            if flipped { context.translateBy(x:0,y:67);context.scaleBy(x:1,y:-1) }
            NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:flipped)
            canvas.draw(canvas.bounds)
            context.flush()
            return Data(bytes:try XCTUnwrap(context.data),count:93*67*4)
        }
        for scale in [CGFloat(1),1.65,2] {
            for flipped in [false,true] {
                for lowLatency in [false,true] {
                    let reference = try pixels(ordinary,scale:scale,flipped:flipped,lowLatency:lowLatency)
                    let rendered = try pixels(shared,scale:scale,flipped:flipped,lowLatency:lowLatency)
                    XCTAssertGreaterThan(Set(reference).count,32)
                    XCTAssertEqual(reference,rendered,"scale \(scale), flipped \(flipped), drag \(lowLatency)")
                }
            }
        }
    }
    func testMixedSizeCompareUsesPhysicalOneToOneAndNormalizedCenters() {
        let shared = ImageTransform(centerX: 0.61, centerY: 0.42, physicalMagnification: 1)
        let panes: [(CGSize, CGSize)] = [
            (.init(width: 8640, height: 5760), .init(width: 960, height: 640)),
            (.init(width: 5760, height: 8640), .init(width: 620, height: 900)),
            (.init(width: 4000, height: 3000), .init(width: 1000, height: 800)),
            (.init(width: 6000, height: 4000), .init(width: 700, height: 500))]
        for backing: CGFloat in [1, 2] {
            for (pixels, viewport) in panes {
                let rect = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport,
                                                            transform: shared, backingScale: backing)
                XCTAssertEqual(rect.width * backing / pixels.width, 1, accuracy: 0.000001)
                XCTAssertEqual(rect.height * backing / pixels.height, 1, accuracy: 0.000001)
                XCTAssertEqual(rect.minX * backing, (rect.minX * backing).rounded(), accuracy: 0.000001)
                XCTAssertEqual((viewport.width / 2 - rect.minX) / rect.width, shared.centerX,
                               accuracy: 0.5 / (rect.width * backing) + 0.000001)
            }
        }
    }
    func testFreeZoomAndFitHaveDifferentExplicitGeometry() {
        let pixels = CGSize(width: 8640, height: 5760), viewport = CGSize(width: 960, height: 640)
        let fit = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport,
                                                  transform: ImageTransform(), backingScale: 2)
        XCTAssertEqual(fit.size, viewport)
        let zoom = ImageViewportGeometry.pointScale(pixelSize: pixels, viewport: viewport,
            transform: ImageTransform(physicalMagnification: 1.25), backingScale: 2)
        XCTAssertEqual(zoom * 2, 1.25, accuracy: 0.000001)
    }
    func testFitUsesSafeViewportWhileZoomCanUseFullCanvas() {
        let pixels = CGSize(width: 1600, height: 1200)
        let viewport = CGSize(width: 1200, height: 800)
        let insets = NSEdgeInsets(top: 70, left: 300, bottom: 90, right: 300)
        let fit = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport,
            transform: ImageTransform(), backingScale: 2, fitInsets: insets)
        XCTAssertEqual(fit, CGRect(x: 300, y: 165, width: 600, height: 450))
        XCTAssertGreaterThanOrEqual(fit.minX, insets.left)
        XCTAssertLessThanOrEqual(fit.maxX, viewport.width - insets.right)
        XCTAssertGreaterThanOrEqual(fit.minY, insets.top)
        XCTAssertLessThanOrEqual(fit.maxY, viewport.height - insets.bottom)

        let zoomed = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport,
            transform: ImageTransform(scale: 2), backingScale: 2, fitInsets: insets)
        XCTAssertEqual(zoomed.size, CGSize(width: 1200, height: 900))
        XCTAssertLessThan(zoomed.minX, fit.minX)
        XCTAssertLessThan(zoomed.minY, fit.minY)
        XCTAssertEqual(ImageViewportGeometry.pointScale(pixelSize: pixels, viewport: viewport,
            transform: ImageTransform(scale: 2), backingScale: 2, fitInsets: insets), 0.75, accuracy: 0.000001)
    }

    @MainActor
    func testBeforeAfterUsesSharedGeometryWithOriginalLeftAndCurrentRight() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let original = solidImage(width: 200, height: 100, color: .green)
        let current = solidImage(width: 200, height: 100, color: .red)
        canvas.update(image: current, actualPixels: false, transform: ImageTransform(),
                      comparisonImage: original, comparisonSplit: 0.5)
        let bitmap = render(canvas)
        let left = try XCTUnwrap(bitmap.colorAt(x: 40, y: 50)?.usingColorSpace(.deviceRGB))
        let right = try XCTUnwrap(bitmap.colorAt(x: 160, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(left.greenComponent, 0.9)
        XCTAssertLessThan(left.redComponent, 0.1)
        XCTAssertGreaterThan(right.redComponent, 0.9)
        XCTAssertLessThan(right.greenComponent, 0.1)
    }

    @MainActor
    func testVerticalAndInvertedWipeUseExpectedRegions() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let reference = solidImage(width: 200, height: 100, color: .green)
        let current = solidImage(width: 200, height: 100, color: .red)
        canvas.update(image: current, actualPixels: false, transform: ImageTransform(), comparisonImage: reference,
                      comparison: .init(mode: .wipeVertical, amount: 0.5))
        var bitmap = render(canvas)
        // NSBitmapImageRep samples use bottom-up coordinates; the canvas is top-down.
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 100, y: 75)?.usingColorSpace(.deviceRGB)).greenComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 100, y: 25)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        canvas.update(image: current, actualPixels: false, transform: ImageTransform(), comparisonImage: reference,
                      comparison: .init(mode: .wipeHorizontal, amount: 0.5, inverted: true))
        bitmap = render(canvas)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 40, y: 50)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        XCTAssertGreaterThan(try XCTUnwrap(bitmap.colorAt(x: 160, y: 50)?.usingColorSpace(.deviceRGB)).greenComponent, 0.9)
    }

    @MainActor
    func testMixUsesCurrentOpacityAndInversion() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let reference = solidImage(width: 200, height: 100, color: .green)
        let current = solidImage(width: 200, height: 100, color: .red)
        for inverted in [false, true] {
            canvas.update(image: current, actualPixels: false, transform: ImageTransform(), comparisonImage: reference,
                          comparison: .init(mode: .mix, amount: 0.25, inverted: inverted))
            let color = try XCTUnwrap(render(canvas).colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, inverted ? 0.75 : 0.25, accuracy: 0.03)
            XCTAssertEqual(color.greenComponent, inverted ? 0.25 : 0.75, accuracy: 0.03)
        }
    }

    @MainActor
    func testDifferenceIsBlackForEqualDisplayPixels() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let reference = solidImage(width: 200, height: 100, color: .green)
        let current = solidImage(width: 200, height: 100, color: .red)
        canvas.update(image: reference, actualPixels: false, transform: ImageTransform(), comparisonImage: reference,
                      comparison: .init(mode: .difference))
        var color = try XCTUnwrap(render(canvas).colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 0, accuracy: 0.03)
        XCTAssertEqual(color.greenComponent, 0, accuracy: 0.03)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.03)
        canvas.update(image: current, actualPixels: false, transform: ImageTransform(), comparisonImage: reference,
                      comparison: .init(mode: .difference))
        color = try XCTUnwrap(render(canvas).colorAt(x: 100, y: 50)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(color.redComponent, 1, accuracy: 0.03)
        XCTAssertEqual(color.greenComponent, 1, accuracy: 0.03)
        XCTAssertEqual(color.blueComponent, 0, accuracy: 0.03)
    }

    @MainActor
    func testCheckerboardAlternatesAndInvertsTiles() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let reference = solidImage(width: 200, height: 100, color: .green)
        let current = solidImage(width: 200, height: 100, color: .red)
        for inverted in [false, true] {
            canvas.update(image: current, actualPixels: false, transform: ImageTransform(), comparisonImage: reference,
                          comparison: .init(mode: .checkerboard, inverted: inverted))
            let bitmap = render(canvas)
            for (x, y, even) in [(20, 20, true), (80, 20, false), (20, 80, false), (80, 80, true)] {
                let color = try XCTUnwrap(bitmap.colorAt(x: x, y: 99 - y)?.usingColorSpace(.deviceRGB))
                let showsCurrent = inverted ? !even : even
                XCTAssertEqual(color.redComponent, showsCurrent ? 1 : 0, accuracy: 0.03)
                XCTAssertEqual(color.greenComponent, showsCurrent ? 0 : 1, accuracy: 0.03)
            }
        }
    }

    @MainActor
    func testMagnifiedCanvasClipsOversizedImageToBounds() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
        let image = solidImage(width: 1600, height: 1200, color: .white)
        canvas.update(image: image, actualPixels: true, transform: ImageTransform())
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 400, pixelsHigh: 400,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let context = NSGraphicsContext(bitmapImageRep: bitmap)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.magenta.setFill(); NSRect(x: 0, y: 0, width: 400, height: 400).fill()
        context.cgContext.translateBy(x: 100, y: 100)
        canvas.draw(NSRect(x: -100, y: -100, width: 400, height: 400))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        // Probe all four neighboring regions. The canvas image must not overwrite them.
        for (x, y) in [(20, 20), (200, 20), (20, 200), (380, 200), (200, 380)] {
            let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, 1, accuracy: 0.01)
            XCTAssertEqual(color.greenComponent, 0, accuracy: 0.01)
            XCTAssertEqual(color.blueComponent, 1, accuracy: 0.01)
        }
        let center = try XCTUnwrap(bitmap.colorAt(x: 200, y: 200)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(center.greenComponent, 1, accuracy: 0.01)
    }
    @MainActor
    func testDoubleClickWheelAndPanPreserveInteractionSemantics() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let image = solidImage(width: 1600, height: 1200, color: .white)
        var latest = ImageTransform(), modes: [Bool] = [], detailRequests = 0
        canvas.onTransform = { latest = $0 }
        canvas.onActualPixelsChange = { modes.append($0) }
        canvas.onRequestDetail = { detailRequests += 1 }
        canvas.update(image: image, actualPixels: false, transform: latest)
        let double = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 200, y: 150),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 1, clickCount: 2, pressure: 1))
        canvas.mouseDown(with: double)
        XCTAssertEqual(modes, [true]); XCTAssertEqual(detailRequests, 1)
        XCTAssertEqual(latest.physicalMagnification, 1)
        let wheelCG = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                                          wheel1: 3, wheel2: 0, wheel3: 0))
        canvas.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: wheelCG)))
        XCTAssertEqual(modes, [true, false], "Free zoom must stop claiming exact 1:1")
        XCTAssertEqual(detailRequests, 2)
        XCTAssertNotEqual(latest.physicalMagnification, 1)
        let beforePan = latest
        let down = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 200, y: 150), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 2, clickCount: 1, pressure: 1))
        let drag = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDragged, location: .init(x: 180, y: 140), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 3, clickCount: 1, pressure: 1))
        canvas.mouseDown(with: down); canvas.mouseDragged(with: drag); canvas.mouseUp(with: drag)
        XCTAssertNotEqual(latest.centerX, beforePan.centerX)
        XCTAssertEqual(latest.physicalMagnification, beforePan.physicalMagnification)
        canvas.mouseDown(with: double)
        XCTAssertNil(latest.physicalMagnification)
        XCTAssertEqual(latest.scale, 1)
    }
    @MainActor
    func testBackgroundChangePreservesImageInstancePixelsZoomPanAndViewport() throws {
        _ = NSApplication.shared
        let source = solidImage(width: 800, height: 200, color: .green)
        let bitmap = try XCTUnwrap(source.representations.first as? NSBitmapImageRep)
        let sourcePixels = Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        let image = DrawObservedImage(size: source.size)
        image.addRepresentation(bitmap)
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        let window = mount(canvas)
        defer { window.close() }
        let state = ImageTransform(scale: 1.4, centerX: 0.61, centerY: 0.5)
        let originalBounds = canvas.bounds
        var transformChanges = 0, detailRequests = 0, modeChanges = 0
        canvas.onTransform = { _ in transformChanges += 1 }
        canvas.onRequestDetail = { detailRequests += 1 }
        canvas.onActualPixelsChange = { _ in modeChanges += 1 }
        canvas.update(image: image, actualPixels: false, transform: state,
                      backgroundColor: NSColor(calibratedWhite: 0.1, alpha: 1))
        let dark = render(canvas)
        canvas.needsDisplay = false
        canvas.update(image: image, actualPixels: false, transform: state,
                      backgroundColor: NSColor(calibratedWhite: 0.95, alpha: 1))
        XCTAssertTrue(canvas.needsDisplay)
        let light = render(canvas)
        let darkMargin = try XCTUnwrap(dark.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        let lightMargin = try XCTUnwrap(light.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(lightMargin.redComponent - darkMargin.redComponent, 0.5)
        let darkPhoto = try XCTUnwrap(dark.colorAt(x: 200, y: 200)?.usingColorSpace(.deviceRGB))
        let lightPhoto = try XCTUnwrap(light.colorAt(x: 200, y: 200)?.usingColorSpace(.deviceRGB))
        XCTAssertEqual(darkPhoto, lightPhoto)
        XCTAssertEqual(image.drawnRects.count, 2, "Both redraws must use the original supplied NSImage instance")
        XCTAssertEqual(image.drawnRects.first, image.drawnRects.last, "Background change must preserve zoom and normalized pan")
        XCTAssertEqual(canvas.bounds, originalBounds)
        XCTAssertEqual(transformChanges, 0)
        XCTAssertEqual(detailRequests, 0)
        XCTAssertEqual(modeChanges, 0)
        XCTAssertEqual(Data(bytes: try XCTUnwrap(bitmap.bitmapData), count: bitmap.bytesPerRow * bitmap.pixelsHigh), sourcePixels)
    }
    @MainActor
    func testDefaultDynamicBackgroundFollowsEffectiveAppearance() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        let window = mount(canvas)
        defer { window.close() }
        canvas.update(image: nil, actualPixels: false, transform: ImageTransform())
        canvas.appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let light = render(canvas)
        canvas.needsDisplay = false
        canvas.appearance = try XCTUnwrap(NSAppearance(named: .darkAqua))
        canvas.viewDidChangeEffectiveAppearance()
        XCTAssertTrue(canvas.needsDisplay)
        let dark = render(canvas)
        let lightColor = try XCTUnwrap(light.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        let darkColor = try XCTUnwrap(dark.colorAt(x: 20, y: 20)?.usingColorSpace(.deviceRGB))
        XCTAssertGreaterThan(lightColor.redComponent - darkColor.redComponent, 0.2)
    }
    @MainActor
    func testIdenticalImageTransformAndActualPixelUpdatesDoNotInvalidateCanvas() throws {
        _ = NSApplication.shared
        let canvas = ImageCanvas(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        var invalidations = 0
        canvas.invalidationObserverForTesting = { invalidations += 1 }
        let image = solidImage(width: 800, height: 600, color: .white)
        let state = ImageTransform(scale: 1.2, centerX: 0.55, centerY: 0.45)
        canvas.update(image: image, actualPixels: false, transform: state, backgroundColor: .black)
        XCTAssertEqual(invalidations, 1)
        canvas.update(image: image, actualPixels: false, transform: state, backgroundColor: .black)
        XCTAssertEqual(invalidations, 1)
        var changed = state; changed.scale = 1.4
        canvas.update(image: image, actualPixels: false, transform: changed, backgroundColor: .black)
        XCTAssertEqual(invalidations, 2)
        canvas.update(image: image, actualPixels: true, transform: changed, backgroundColor: .black)
        XCTAssertEqual(invalidations, 3)
        canvas.update(image: image, actualPixels: true, transform: changed, backgroundColor: .black)
        XCTAssertEqual(invalidations, 3, "Resolved physical magnification must not cause perpetual redraws")
    }
    func testInterpolationPolicyPreservesExactAndSettledQuality() {
        XCTAssertEqual(ImageCanvasInterpolationPolicy.resolve(exactPixels: true, lowLatency: true), .none)
        XCTAssertEqual(ImageCanvasInterpolationPolicy.resolve(exactPixels: false, lowLatency: true), .medium)
        XCTAssertEqual(ImageCanvasInterpolationPolicy.resolve(exactPixels: false, lowLatency: false), .high)
    }
    @MainActor
    private func mount(_ canvas: ImageCanvas) -> NSWindow {
        // Detached NSViews intentionally discard needsDisplay; retain an unshown
        // native window to verify invalidation without presenting test UI.
        let window = NSWindow(contentRect: canvas.bounds, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = canvas
        return window
    }
    @MainActor
    private func render(_ canvas: ImageCanvas) -> NSBitmapImageRep {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.bounds.width),
            pixelsHigh: Int(canvas.bounds.height), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        canvas.draw(canvas.bounds)
        NSGraphicsContext.current?.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap
    }
    @MainActor
    private func solidImage(width: Int, height: Int, color: NSColor) -> NSImage {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        color.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        let image = NSImage(size: .init(width: width, height: height)); image.addRepresentation(bitmap)
        return image
    }
}
