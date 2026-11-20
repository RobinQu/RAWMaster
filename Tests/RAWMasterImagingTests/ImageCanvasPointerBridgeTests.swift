import XCTest
import AppKit
@testable import RAWMasterImaging

final class ImageCanvasPointerBridgeTests: XCTestCase {
  @MainActor
  private func canvas() -> ImageCanvas {
    _ = NSApplication.shared
    let view = ImageCanvas(frame:.init(x:0,y:0,width:400,height:300))
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:80,pixelsHigh:40,bitsPerSample:8,
      samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:320,bitsPerPixel:32)!
    bitmap.bitmapData!.initialize(repeating:255,count:bitmap.bytesPerRow*bitmap.pixelsHigh)
    let image = NSImage(size:.init(width:80,height:40)); image.addRepresentation(bitmap)
    view.update(image:image,actualPixels:false,transform:.init())
    view.frameID = UUID()
    return view
  }
  @MainActor
  private func event(_ type: NSEvent.EventType,x: CGFloat = 180,y: CGFloat = 150,clicks: Int = 1) throws -> NSEvent {
    try XCTUnwrap(NSEvent.mouseEvent(with:type,location:.init(x:x,y:y),modifierFlags:[.shift],timestamp:12.5,
      windowNumber:0,context:nil,eventNumber:1,clickCount:clicks,pressure:0))
  }
  @MainActor
  func testConsumedGestureKeepsOriginalOwnerAcrossCallbackAndRenderedFrameChanges() throws {
    let view = canvas(), beganFrame = view.frameID
    var original: [ImageCanvasPointerEvent] = [], replacement: [ImageCanvasPointerEvent] = []
    var transforms = 0, details = 0, modes = 0
    view.onTransform = { _ in transforms += 1 }; view.onRequestDetail = { details += 1 }
    view.onActualPixelsChange = { _ in modes += 1 }
    view.setInteractionHandlers(pointer:{ original.append($0); return true },viewport:nil)
    view.mouseDown(with:try event(.leftMouseDown,clicks:2))
    let newFrame = UUID(); view.frameID = newFrame
    view.setInteractionHandlers(pointer:{ replacement.append($0); return true },viewport:nil)
    view.mouseDragged(with:try event(.leftMouseDragged,x:215,y:160))
    view.mouseUp(with:try event(.leftMouseUp,x:230,y:165))
    XCTAssertEqual(original.map(\.phase),[.began,.changed,.ended]); XCTAssertTrue(replacement.isEmpty)
    XCTAssertEqual(Set(original.map(\.gestureID)).count,1)
    XCTAssertTrue(original.allSatisfy { $0.beganFrameID == beganFrame })
    XCTAssertEqual(original.last?.viewport.frameID,newFrame)
    XCTAssertTrue(original.allSatisfy { !$0.supportsPressure && $0.pressure == 1 })
    XCTAssertEqual(original[0].modifiersRawValue,UInt64(NSEvent.ModifierFlags.shift.rawValue))
    XCTAssertEqual(original[0].eventTimestamp,12.5)
    XCTAssertEqual(transforms,0); XCTAssertEqual(details,0); XCTAssertEqual(modes,0)
    view.clearInteractionHandlers()
  }
  @MainActor
  func testDisableAndResignCancelExactlyOnceAndDoNotCommitStaleMouseUp() throws {
    let view = canvas(); var received: [ImageCanvasPointerEvent] = []
    let handler: @MainActor (ImageCanvasPointerEvent) -> Bool = { received.append($0); return true }
    view.setInteractionHandlers(pointer:handler,viewport:nil)
    view.mouseDown(with:try event(.leftMouseDown))
    view.setInteractionHandlers(pointer:nil,viewport:nil)
    view.mouseUp(with:try event(.leftMouseUp))
    XCTAssertEqual(received.map(\.phase),[.began,.cancelled])
    view.setInteractionHandlers(pointer:handler,viewport:nil)
    view.mouseDown(with:try event(.leftMouseDown))
    _ = view.resignFirstResponder(); _ = view.resignFirstResponder()
    view.mouseUp(with:try event(.leftMouseUp))
    XCTAssertEqual(received.map(\.phase),[.began,.cancelled,.began,.cancelled])
    XCTAssertNotEqual(received[0].gestureID,received[2].gestureID)
    view.clearInteractionHandlers()
  }
  @MainActor
  func testReentrantDisableDuringBeginCannotRetainGestureOwner() throws {
    let view = canvas(); var phases: [ImageCanvasPointerPhase] = []
    view.setInteractionHandlers(pointer:{ event in
      phases.append(event.phase)
      if event.phase == .began { view.setInteractionHandlers(pointer:nil,viewport:nil) }
      return true
    },viewport:nil)
    view.mouseDown(with:try event(.leftMouseDown))
    view.mouseDragged(with:try event(.leftMouseDragged)); view.mouseUp(with:try event(.leftMouseUp))
    XCTAssertEqual(phases,[.began,.cancelled])
    view.clearInteractionHandlers()
  }
  @MainActor
  func testViewportUsesSharedGeometryDeduplicatesAndPreservesOutsidePointer() throws {
    let view = canvas(); var snapshots: [ImageCanvasViewportSnapshot] = [], points: [ImageCanvasPointerEvent] = []
    view.setInteractionHandlers(pointer:{ points.append($0); return true },viewport:{ snapshots.append($0) })
    view.layout(); view.layout()
    XCTAssertEqual(snapshots.count,1)
    let first = try XCTUnwrap(snapshots.first)
    XCTAssertEqual(first.frameID,view.frameID); XCTAssertEqual(first.imagePixelSize,.init(width:80,height:40))
    XCTAssertEqual(first.imageRect,ImageViewportGeometry.imageRect(pixelSize:first.imagePixelSize,
      viewport:first.viewportSize,transform:first.transform,backingScale:first.backingScale))
    let state = ImageTransform(scale:2,centerX:0.6,centerY:0.4)
    view.update(image:nil,actualPixels:false,transform:state)
    // A new image/frame is a viewport change; it is never synthesized from a stale bitmap size.
    view.layout(); XCTAssertEqual(snapshots.count,2); XCTAssertEqual(snapshots.last?.imagePixelSize,.zero)
    let withImage = canvas(); defer { withImage.clearInteractionHandlers(); view.clearInteractionHandlers() }
    withImage.setInteractionHandlers(pointer:{ points.append($0); return true },viewport:nil)
    let outside = try event(.leftMouseDown,x:-30,y:340)
    withImage.mouseDown(with:outside)
    let p = try XCTUnwrap(points.last)
    XCTAssertEqual(p.locationInView,withImage.convert(outside.locationInWindow,from:nil))
    XCTAssertFalse(withImage.bounds.contains(p.locationInView),"Native bridge must not clamp a hit into the image or view")
    withImage.mouseUp(with:try event(.leftMouseUp,x:-30,y:340))
  }
}
