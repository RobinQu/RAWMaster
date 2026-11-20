import XCTest
@testable import RAWMaster

final class NavigationMaterialPolicyTests: XCTestCase {
    func testEachAccessibilityPreferenceOverridesBothPlatformMaterials() {
        for supportsGlass in [false, true] {
            XCTAssertEqual(FloatingControlSurfacePolicy.resolve(reduceTransparency: true, increasedContrast: false, supportsGlass: supportsGlass), .opaque)
            XCTAssertEqual(FloatingControlSurfacePolicy.resolve(reduceTransparency: false, increasedContrast: true, supportsGlass: supportsGlass), .opaque)
            XCTAssertEqual(FloatingControlSurfacePolicy.resolve(reduceTransparency: true, increasedContrast: true, supportsGlass: supportsGlass), .opaque)
        }
    }

    func testDefaultMaterialFollowsPlatformCapability() {
        XCTAssertEqual(FloatingControlSurfacePolicy.resolve(reduceTransparency: false, increasedContrast: false, supportsGlass: true), .glass)
        XCTAssertEqual(FloatingControlSurfacePolicy.resolve(reduceTransparency: false, increasedContrast: false, supportsGlass: false), .material)
    }
}
