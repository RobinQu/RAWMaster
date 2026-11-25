import XCTest
@testable import RAWMasterImaging

/// The speed profile only changes which frame the canvas asks for. These are the decisions the
/// controller delegates, pinned so a refactor cannot silently upgrade a gesture or downgrade a
/// 1:1 inspection.
final class PreviewQualityPolicyTests: XCTestCase {
  func testBalancedKeepsEveryOneToOneFrameNative() {
    for interacting in [false, true] {
      XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: true, interacting: interacting,
        overlayOnly: false, turbo: false), .detail)
    }
  }

  func testTurboFallsBackToTheProxyOnlyWhileAGestureIsInFlight() {
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: true, interacting: true,
      overlayOnly: false, turbo: true), .interactive)
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: true, interacting: false,
      overlayOnly: false, turbo: true), .detail)
  }

  /// A crop overlay only moves the mask, so the turbo fallback must not hide new pixels behind it.
  func testTurboKeepsNativePixelsWhenOnlyTheOverlayChanged() {
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: true, interacting: true,
      overlayOnly: true, turbo: true), .detail)
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: false, interacting: true,
      overlayOnly: true, turbo: true), .settled)
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: false, interacting: true,
      overlayOnly: true, turbo: false), .settled)
  }

  func testFitZoomStillUsesTheGesturesProxyAndTheSettledFrameOtherwise() {
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: false, interacting: true,
      overlayOnly: false, turbo: false), .interactive)
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: false, interacting: false,
      overlayOnly: false, turbo: false), .settled)
    XCTAssertEqual(PreviewQualityPolicy.quality(actualPixels: false, interacting: false,
      overlayOnly: false, turbo: true), .settled)
  }

  func testTurboSettlesTheVisibleWindowAndBalancedKeepsThePanMargin() {
    XCTAssertEqual(PreviewQualityPolicy.windowMargin(interacting: true, turbo: true), 0)
    XCTAssertEqual(PreviewQualityPolicy.windowMargin(interacting: false, turbo: true),
      PreviewPerformancePreferences.settledWindowMargin)
    XCTAssertEqual(PreviewQualityPolicy.windowMargin(interacting: true, turbo: false),
      PreviewPerformancePreferences.settledWindowMargin)
    XCTAssertGreaterThan(PreviewPerformancePreferences.settledWindowMargin, 0)
  }

  func testStoredValuesFallBackToBalanced() {
    let saved = PreviewPerformancePreferences.mode
    defer { PreviewPerformancePreferences.mode = saved }
    PreviewPerformancePreferences.apply(stored: "turbo")
    XCTAssertTrue(PreviewPerformancePreferences.isTurbo)
    PreviewPerformancePreferences.apply(stored: "nonsense")
    XCTAssertEqual(PreviewPerformancePreferences.mode, .balanced)
    PreviewPerformancePreferences.apply(stored: "")
    XCTAssertEqual(PreviewPerformancePreferences.mode, .balanced)
  }
}
