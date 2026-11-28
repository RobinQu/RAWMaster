import XCTest
import AppKit
import CoreGraphics
@testable import RAWMasterImaging

/// The 1:1 canvas can receive a bitmap that covers only part of the canvas. These are the
/// geometry rules that keep navigation, drawing and the served-window decision consistent.
final class ImageViewportWindowGeometryTests: XCTestCase {
  private let canvas = CGRect(x: 0, y: 0, width: 1000, height: 800)

  func testWindowRectMapsTopLeftNormalizedWindowIntoTheCanvasRect() {
    let window = CGRect(x: 0.25, y: 0.5, width: 0.5, height: 0.25)
    let rect = ImageViewportGeometry.windowRect(window, in: canvas)
    // The canvas view is flipped, so a top-left origin window starts at minY.
    XCTAssertEqual(rect, CGRect(x: 250, y: 400, width: 500, height: 200))
  }

  func testNilWindowCoversTheWholeCanvas() {
    XCTAssertEqual(ImageViewportGeometry.windowRect(nil, in: canvas), canvas)
  }

  func testWindowRectIsClippedToTheCanvas() {
    let rect = ImageViewportGeometry.windowRect(CGRect(x: 0.9, y: 0.9, width: 0.5, height: 0.5), in: canvas)
    XCTAssertEqual(rect, CGRect(x: 900, y: 720, width: 100, height: 80))
  }

  func testVisibleWindowIsTheIntersectionOfCanvasAndBounds() {
    // A 1000-wide canvas drawn from x=-250 into a 500-wide view sees 0.25...0.75 of it.
    let destination = CGRect(x: -250, y: 0, width: 1000, height: 800)
    let window = CGRect(x: 0, y: 0, width: 500, height: 800)
    let visible = try? XCTUnwrap(ImageViewportGeometry.visibleWindow(destination: destination, bounds: window))
    XCTAssertEqual(visible?.minX ?? .nan, 0.25, accuracy: 1e-9)
    XCTAssertEqual(visible?.maxX ?? .nan, 0.75, accuracy: 1e-9)
    XCTAssertEqual(visible?.minY ?? .nan, 0, accuracy: 1e-9)
    XCTAssertEqual(visible?.maxY ?? .nan, 1, accuracy: 1e-9)
  }

  func testVisibleWindowIsClampedWhenTheImageIsSmallerThanTheView() {
    let destination = CGRect(x: 100, y: 100, width: 500, height: 400)
    let visible = ImageViewportGeometry.visibleWindow(destination: destination, bounds: canvas)
    XCTAssertEqual(visible, CGRect(x: 0, y: 0, width: 1, height: 1))
  }

  func testServedWindowAddsMarginAndStaysInsideTheUnitCanvas() {
    let visible = CGRect(x: 0.1, y: 0.2, width: 0.2, height: 0.2)
    let served = ImageViewportGeometry.servedWindow(visible: visible, margin: 0.5)
    XCTAssertEqual(served.minX, 0, accuracy: 1e-9)   // 0.1 - 0.1 clamps at 0
    XCTAssertEqual(served.minY, 0.1, accuracy: 1e-9)
    XCTAssertEqual(served.maxX, 0.4, accuracy: 1e-9)
    XCTAssertEqual(served.maxY, 0.5, accuracy: 1e-9)
  }

  func testQuantizationSnapsOutwardSoItNeverDropsAVisiblePixel() {
    let window = CGRect(x: 0.031, y: 0.0625, width: 0.4374, height: 0.1876)
    let snapped = ImageViewportGeometry.quantized(window, steps: 32)
    XCTAssertLessThanOrEqual(snapped.minX, window.minX)
    XCTAssertLessThanOrEqual(snapped.minY, window.minY)
    XCTAssertGreaterThanOrEqual(snapped.maxX, window.maxX)
    XCTAssertGreaterThanOrEqual(snapped.maxY, window.maxY)
    for value in [snapped.minX, snapped.minY, snapped.maxX, snapped.maxY] {
      XCTAssertEqual((value * 32).rounded(), value * 32, accuracy: 1e-9, "not on the 1/32 grid")
    }
  }

  func testCoversRequiresTheWholeVisibleRect() {
    let served = CGRect(x: 0.2, y: 0.2, width: 0.4, height: 0.4)
    XCTAssertTrue(ImageViewportGeometry.window(served, covers: CGRect(x: 0.25, y: 0.25, width: 0.2, height: 0.2)))
    XCTAssertFalse(ImageViewportGeometry.window(served, covers: CGRect(x: 0.5, y: 0.25, width: 0.2, height: 0.2)))
    XCTAssertFalse(ImageViewportGeometry.window(served, covers: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1)))
  }

  func testBudgetedDetailWindowUsesThePixelGridAndFitsTwoBitmaps() throws {
    let native = CGSize(width: 9504, height: 6336)
    let visible = CGRect(x: 3024 / native.width, y: 2682 / native.height,
                         width: 3680 / native.width, height: 1804 / native.height)
    let budget = 128 * 1024 * 1024
    let planned = try XCTUnwrap(ImageViewportGeometry.budgetedNativeWindow(
      visible: visible, nativeSize: native, cacheBytes: budget, margin: 0.5))
    XCTAssertTrue(ImageViewportGeometry.window(planned, covers: visible, tolerance: 1e-9))
    XCTAssertGreaterThan(planned.width, visible.width)
    XCTAssertGreaterThan(planned.height, visible.height)
    let grid = [planned.minX * native.width, planned.minY * native.height,
                planned.width * native.width, planned.height * native.height]
    for coordinate in grid { XCTAssertEqual(coordinate, coordinate.rounded(), accuracy: 1e-9) }
    let row = ((4 * Int(grid[2].rounded()) + 63) / 64) * 64
    XCTAssertLessThanOrEqual(2 * row * Int(grid[3].rounded()), budget)
  }

  func testVisiblePixelsArePreservedWhenTwoBitmapsCannotFit() throws {
    let native = CGSize(width: 9504, height: 6336)
    let visible = CGRect(x: 0, y: 0, width: 6016 / native.width, height: 3384 / native.height)
    let planned = try XCTUnwrap(ImageViewportGeometry.budgetedNativeWindow(
      visible: visible, nativeSize: native, cacheBytes: 128 * 1024 * 1024, margin: 0.5))
    XCTAssertTrue(ImageViewportGeometry.window(planned, covers: visible, tolerance: 1e-9))
    XCTAssertEqual(planned.width * native.width, 6016, accuracy: 1)
    XCTAssertEqual(planned.height * native.height, 3384, accuracy: 1)
    XCTAssertEqual(planned.origin, .zero)
  }

  /// The canvas draws a windowed bitmap into the corresponding part of the whole-canvas rect,
  /// with the rest of the canvas left to the background.
  @MainActor func testWindowedBitmapDrawsOnlyIntoItsCanvasRect() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
    let red = try XCTUnwrap(CGContext(data: nil, width: 50, height: 50, bitsPerComponent: 8,
      bytesPerRow: 50 * 4, space: space, bitmapInfo: bitmapInfo))
    red.setFillColor(NSColor.red.cgColor); red.fill(CGRect(x: 0, y: 0, width: 50, height: 50))
    let image = NSImage(cgImage: try XCTUnwrap(red.makeImage()), size: .init(width: 50, height: 50))

    let canvas = ImageCanvas(frame: .init(x: 0, y: 0, width: 100, height: 100))
    // Whole canvas is 100x100 px; the bitmap covers its right half.
    // Fit-relative scale 1 with a canvas equal to the viewport gives a 1:1 canvas rect.
    canvas.update(image: image, actualPixels: false, transform: .init(scale: 1),
                  backgroundColor: .black, fitInsets: .init(top: 0, left: 0, bottom: 0, right: 0),
                  window: CGRect(x: 0.5, y: 0, width: 0.5, height: 1),
                  canvasPixelSize: CGSize(width: 100, height: 100))

    let output = try XCTUnwrap(CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
      bytesPerRow: 100 * 4, space: space, bitmapInfo: bitmapInfo))
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(cgContext: output, flipped: true)
    canvas.draw(canvas.bounds)
    output.flush()

    let bytes = try XCTUnwrap(output.data).assumingMemoryBound(to: UInt8.self)
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
      let i = (y * 100 + x) * 4
      return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }
    let inside = pixel(80, 50), outside = pixel(20, 50)
    XCTAssertGreaterThan(inside.0, 200, "the window must show the bitmap")
    XCTAssertLessThan(inside.1, 60)
    XCTAssertLessThan(outside.0, 40, "the rest of the canvas stays background")
    XCTAssertLessThan(outside.1, 40)
  }

  /// A pan inside the margin keeps the same window; leaving it produces one new window.
  func testPanningInsideTheServedWindowDoesNotRequestANewOne() {    let step: CGFloat = 0.05
    let served = ImageViewportGeometry.quantized(
      ImageViewportGeometry.servedWindow(visible: CGRect(x: 0.35, y: 0.35, width: 0.3, height: 0.3), margin: 0.5),
      steps: 32)
    for offset in stride(from: CGFloat(0), through: 0.14, by: step) {
      let visible = CGRect(x: 0.35 + offset, y: 0.35, width: 0.3, height: 0.3)
      XCTAssertTrue(ImageViewportGeometry.window(served, covers: visible),
                    "a pan of \(offset) must stay inside the served window")
    }
    let outside = CGRect(x: 0.66, y: 0.35, width: 0.3, height: 0.3)
    XCTAssertFalse(ImageViewportGeometry.window(served, covers: outside))
  }
}
