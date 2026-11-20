import XCTest
import CoreGraphics
import RAWMasterCore
@testable import RAWMaster

final class PhotosCropInteractionTests: XCTestCase {
    func testContinuousPlaneAspectAndRasterOffsetAreNeverReconstructedFromIntegerPreview() throws {
        let geometry = DevelopmentGeometryV3(version: .projectiveV3_1, straightenDegrees: 13.7, verticalPerspective: 12, horizontalPerspective: -9)
        let plane = try geometry.mapping(sourceSize: .init(width: 1203, height: 809)).cropPlane
        XCTAssertNotEqual(plane.rect.height, Double(plane.identityRasterSize.height))
        let imageRect = CGRect(x: 17, y: 31, width: 687, height: 419)
        let top = try PhotosCropInteraction.planePoint(imageRect.origin, imageRect: imageRect, plane: plane)
        XCTAssertEqual(top.y, plane.identityRasterRect.y / plane.rect.height, accuracy: 1e-14)
        XCTAssertGreaterThan(top.y, 0, "Fractional inward top offset must not be discarded")
        let fitted = try PhotosCropInteraction.fitted(.init(), ratio: 16.0 / 9, plane: plane.rect)
        XCTAssertEqual(fitted.width * plane.rect.width / (fitted.height * plane.rect.height), 16.0 / 9, accuracy: 1e-12)
        let rect = PhotosCropInteraction.screenRect(fitted, imageRect: imageRect, plane: plane)
        let roundtrip = try PhotosCropInteraction.planePoint(rect.origin, imageRect: imageRect, plane: plane)
        XCTAssertEqual(roundtrip.x, fitted.x, accuracy: 1e-14); XCTAssertEqual(roundtrip.y, fitted.y, accuracy: 1e-14)
        // A crop identity raster's integer aspect is deliberately a different value here.
        XCTAssertNotEqual(plane.rect.width / plane.rect.height, Double(plane.identityRasterSize.width) / Double(plane.identityRasterSize.height))
    }
    func testAllEightResizeHandlesPreserveLockedPhysicalAspectAndBounds() throws {
        let plane = DevelopmentContinuousRectV3(x: 0, y: 0, width: 1198.23, height: 803.61)
        let start = try PhotosCropInteraction.fitted(.init(x: 0.1, y: 0.15, width: 0.7, height: 0.7), ratio: 4.0 / 5, plane: plane)
        for handle in PhotosCropHandle.allCases where handle != .center && handle != .straighten {
            for delta in [CGPoint(x: 0.13, y: -0.17), CGPoint(x: -3, y: 4)] {
                let next = try PhotosCropInteraction.resized(start, handle: handle, delta: delta, plane: plane, ratio: 4.0 / 5)
                XCTAssertGreaterThan(next.width, 0); XCTAssertGreaterThan(next.height, 0)
                XCTAssertGreaterThanOrEqual(next.x, -1e-14); XCTAssertGreaterThanOrEqual(next.y, -1e-14)
                XCTAssertLessThanOrEqual(next.x + next.width, 1 + 1e-14); XCTAssertLessThanOrEqual(next.y + next.height, 1 + 1e-14)
                XCTAssertEqual(next.width * plane.width / (next.height * plane.height), 4.0 / 5, accuracy: 1e-12)
            }
        }
        let moved = try PhotosCropInteraction.resized(start, handle: .center, delta: .init(x: 5, y: -5), plane: plane, ratio: 4.0 / 5)
        XCTAssertEqual(moved.width, start.width); XCTAssertEqual(moved.height, start.height)
        XCTAssertEqual(moved.x + moved.width, 1, accuracy: 1e-14); XCTAssertEqual(moved.y, 0)
    }
    func testFreeformEdgesAndCustomInputsRejectNonFiniteAndPreserveUnchangedReads() throws {
        let plane = DevelopmentContinuousRectV3(x: 0, y: 0, width: 1000.4, height: 650.8)
        let start = NormalizedCrop(x: 0.1, y: 0.2, width: 0.7, height: 0.6)
        let left = try PhotosCropInteraction.resized(start, handle: .left, delta: .init(x: 0.1, y: 0.4), plane: plane, ratio: nil)
        XCTAssertEqual(left.y, start.y); XCTAssertEqual(left.height, start.height)
        XCTAssertEqual(left.x + left.width, start.x + start.width, accuracy: 1e-14)
        for handle in [PhotosCropHandle.left, .right] {
            let resized = try PhotosCropInteraction.resized(start, handle: handle, delta: .init(x: 0.05, y: 0.1), plane: plane, ratio: nil)
            XCTAssertEqual(resized.y.bitPattern, start.y.bitPattern)
            XCTAssertEqual(resized.height.bitPattern, start.height.bitPattern)
        }
        for handle in [PhotosCropHandle.top, .bottom] {
            let resized = try PhotosCropInteraction.resized(start, handle: handle, delta: .init(x: 0.1, y: 0.05), plane: plane, ratio: nil)
            XCTAssertEqual(resized.x.bitPattern, start.x.bitPattern)
            XCTAssertEqual(resized.width.bitPattern, start.width.bitPattern)
        }
        let locked = try PhotosCropInteraction.fitted(start, ratio: 4.0 / 5, plane: plane)
        for handle in PhotosCropHandle.allCases {
            XCTAssertEqual(try PhotosCropInteraction.resized(start, handle: handle, delta: .zero, plane: plane, ratio: nil), start)
            XCTAssertEqual(try PhotosCropInteraction.resized(locked, handle: handle, delta: .zero, plane: plane, ratio: 4.0 / 5), locked)
        }
        XCTAssertEqual(try PhotosCropInteraction.fitted(start, ratio: nil, plane: plane), start)
        var constraint = PhotosCropConstraint(aspect: .original, orientation: .portrait)
        XCTAssertEqual(try constraint.ratio(source: .init(width: 6000, height: 4000)), 2.0 / 3)
        constraint.aspect = .custom; constraint.customWidth = .nan
        XCTAssertThrowsError(try constraint.ratio(source: .init(width: 6000, height: 4000)))
        constraint.customWidth = 0
        XCTAssertThrowsError(try constraint.ratio(source: .init(width: 6000, height: 4000)))
        XCTAssertThrowsError(try PhotosCropInteraction.resized(start, handle: .left, delta: .init(x: CGFloat.infinity, y: 0), plane: plane, ratio: nil))
    }
}
