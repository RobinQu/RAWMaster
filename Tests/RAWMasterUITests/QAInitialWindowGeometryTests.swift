import AppKit
import XCTest
@testable import RAWMaster
import RAWMasterImaging

final class QAInitialWindowGeometryTests: XCTestCase {
    func testOnlyExactQAValidWindowSizeChangesTheProductionDefault() {
        let bundle = "io.robinqu.RAWMaster.preview022", key = "RAWMASTER_QA_WINDOW_SIZE_POINTS"
        XCTAssertEqual(QAInitialWindowGeometry.productionSize, CGSize(width: 1480, height: 940))
        XCTAssertEqual(QAInitialWindowGeometry.parse(bundleIdentifier: bundle, environment: [key: "1610x1027"]), CGSize(width: 1610, height: 1027))
        XCTAssertNil(QAInitialWindowGeometry.parse(bundleIdentifier: "io.robinqu.RAWMaster", environment: [key: "1610x1027"]))
        XCTAssertNil(QAInitialWindowGeometry.parse(bundleIdentifier: nil, environment: [key: "1610x1027"]))
        XCTAssertNil(QAInitialWindowGeometry.parse(bundleIdentifier: bundle, environment: [:]))
        for bad in ["", "1610", "1610xx1027", "1610X1027", "nanx1027", "infx1027", "1610xnan", "1099x1027", "1921x1027", "1610x719", "1610x1201", "-1610x1027"] {
            XCTAssertNil(QAInitialWindowGeometry.parse(bundleIdentifier: bundle, environment: [key: bad]), bad)
        }
        let pixels = CGSize(width: 2400, height: 1600)
        let a = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: .init(width: 1012, height: 675), transform: .init(), backingScale: 2)
        XCTAssertEqual(a.width, 1012, accuracy: 0.000001); XCTAssertEqual(a.height, 674.6666666667, accuracy: 0.000001)
        let b = ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: .init(width: 1012.5, height: 675), transform: .init(), backingScale: 2)
        XCTAssertEqual(b.width, 1012.5, accuracy: 0.000001); XCTAssertEqual(b.height, 675, accuracy: 0.000001)
        // These are only geometry calculations, not a claimed Photos screen match.
    }
    @MainActor func testViewportEvidenceKeepsOnlyBoundedActualSettledFitScalars() {
        let store = QAInitialWindowGeometry.Evidence(), id = UUID(), requested = CGSize(width: 1610, height: 1027)
        func value(_ width: CGFloat, hasFrame: Bool = true, transform: ImageTransform = .init()) -> ImageCanvasViewportSnapshot {
            let viewport = CGSize(width: width, height: 675), pixels = CGSize(width: 2400, height: 1600)
            return .init(frameID: hasFrame ? id : nil, viewportSize: viewport, imagePixelSize: pixels,
                imageRect: ImageViewportGeometry.imageRect(pixelSize: pixels, viewport: viewport, transform: transform, backingScale: 2),
                backingScale: 2, transform: transform)
        }
        store.append(value(1012), requested: requested, frameID: id, quality: .interactive, at: 1)
        store.append(value(1012), requested: requested, frameID: UUID(), quality: .settled, at: 2)
        store.append(value(1012, hasFrame: false), requested: requested, frameID: nil, quality: .settled, at: 3)
        store.append(value(1012, transform: .init(scale: 2)), requested: requested, frameID: id, quality: .settled, at: 4)
        XCTAssertTrue(store.rows.isEmpty)
        let first = value(1012)
        store.append(first, requested: requested, frameID: id, quality: .settled, at: 5)
        store.append(first, requested: requested, frameID: id, quality: .settled, at: 6)
        XCTAssertEqual(store.rows.count, 1); XCTAssertEqual(store.rows[0].snapshot, first); XCTAssertEqual(store.rows[0].at, 5)
        for i in 1...8 { store.append(value(1012 + CGFloat(i)), requested: requested, frameID: id, quality: .settled, at: UInt64(6+i)) }
        XCTAssertEqual(store.rows.count, 8); XCTAssertTrue(store.overflow)
        XCTAssertEqual(store.seal()?.count, 8); XCTAssertNil(store.seal())
        store.append(value(1200), requested: requested, frameID: id, quality: .settled, at: 99)
        XCTAssertEqual(store.rows.count, 8)
        XCTAssertEqual(store.rows[0].fields["boundary"] as? String, "actual-AppKit-viewport; not-WindowServer-presentation")
    }
}
