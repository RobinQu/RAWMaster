import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class PhotosHistogramInteractionTests: XCTestCase {
    func testCameraRawZoneBoundariesAndParameterMapping() {
        let cases: [(Double, PhotosHistogramZone)] = [
            (-0.1, .blacks), (0, .blacks), (0.099, .blacks), (0.1, .shadows),
            (0.299, .shadows), (0.3, .exposure), (0.699, .exposure),
            (0.7, .highlights), (0.899, .highlights), (0.9, .whites), (1.1, .whites)
        ]
        for (fraction, expected) in cases { XCTAssertEqual(PhotosHistogramZone.at(fraction), expected) }
        XCTAssertEqual(PhotosHistogramZone.blacks.fieldID, "blackPoint")
        XCTAssertEqual(PhotosHistogramZone.shadows.fieldID, "shadows")
        XCTAssertEqual(PhotosHistogramZone.exposure.fieldID, "exposure")
        XCTAssertEqual(PhotosHistogramZone.highlights.fieldID, "highlights")
        XCTAssertEqual(PhotosHistogramZone.whites.fieldID, "whites")
        for zone in PhotosHistogramZone.allCases {
            let field = PhotosScalarField.fields(for: .light, noiseReduction: nil).first { $0.id == zone.fieldID }
            XCTAssertNotNil(field, zone.rawValue)
        }
    }
}
