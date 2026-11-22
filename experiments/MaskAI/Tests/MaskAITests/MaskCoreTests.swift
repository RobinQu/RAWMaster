import XCTest
@testable import MaskAI

final class MaskCoreTests: XCTestCase {
    func testMaskBooleanAndInvert() throws {
        let a = try MaskImage(width: 2, height: 2, values: [255, 128, 0, 255])
        let b = try MaskImage(width: 2, height: 2, values: [255, 255, 255, 0])
        XCTAssertEqual(try a.combined(with: b, operation: .add).values, [255, 255, 255, 255])
        XCTAssertEqual(try a.combined(with: b, operation: .subtract).values, [0, 0, 0, 255])
        XCTAssertEqual(try a.combined(with: b, operation: .intersect).values, [255, 128, 0, 0])
        XCTAssertEqual(a.inverted().values, [0, 127, 255, 0])
        XCTAssertEqual(a.selectedPixelCount, 3)
    }

    func testResizeAndCropKeepTopLeftCoordinates() throws {
        let mask = try MaskImage(width: 4, height: 4, values: [UInt8](repeating: 0, count: 16))
        let selected = try mask.combined(with: MaskImage(width: 4, height: 4, values: [
            0, 0, 0, 0,
            0, 255, 255, 0,
            0, 255, 255, 0,
            0, 0, 0, 0,
        ]), operation: .add)
        let crop = try selected.cropped(to: NormalizedRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        XCTAssertEqual(crop.values, [255, 255, 255, 255])
        let doubled = try crop.resized(toWidth: 4, toHeight: 4)
        XCTAssertEqual(doubled.width, 4)
        XCTAssertGreaterThan(doubled.coverage, 0.99)
    }

    func testPromptValidation() throws {
        XCTAssertThrowsError(try ObjectPrompt().validated())
        XCTAssertThrowsError(try ObjectPrompt(positivePoints: [.init(x: 2, y: 0)]).validated())
        XCTAssertNoThrow(try ObjectPrompt(box: .init(x: 0.1, y: 0.1, width: 0.5, height: 0.5)).validated())
    }

    func testCameraRawLandscapeCoverageAndADE20KMapping() {
        XCTAssertEqual(LandscapeMaskTarget.allCases.count, 8)
        XCTAssertEqual(SceneMasker.ade20kIndices(for: .sky), [2])
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .snow).isEmpty)
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .architecture).contains(1))
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .vegetation).contains(4))
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .water).contains(26))
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .naturalGround).contains(13))
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .artificialGround).contains(6))
        XCTAssertTrue(SceneMasker.ade20kIndices(for: .mountains).contains(16))
    }

    func testPersonPartCoverage() {
        XCTAssertEqual(PersonMaskTarget.allCases.count, 10)
        XCTAssertTrue(PersonMaskTarget.allCases.contains(.entirePerson))
        XCTAssertTrue(PersonMaskTarget.allCases.contains(.irisPupil))
        XCTAssertTrue(PersonMaskTarget.allCases.contains(.teeth))
    }

    func testFaceRasterizationAndColorPrior() throws {
        let points = (0..<478).map { _ in NormalizedPoint(x: 0, y: 0) }
        XCTAssertThrowsError(try FaceGeometry.rasterize(points: points, polygons: [[0, 1, 500]], width: 4, height: 4))
    }

    func testModelCatalogPinsEveryModel() {
        for model in MaskAIModel.allCases {
            XCTAssertEqual(model.expectedSHA256.count, 64)
            XCTAssertTrue(model.relativePath.hasSuffix(".onnx"))
        }
    }

    func testNativeImagePreprocessing() throws {
        let image = try NativeImage(width: 1, height: 1, rgba: [255, 128, 0, 255])
        assertFloatArraysEqual(image.nchwFloat32(normalization: .zeroToOne), [1, 128 / 255, 0])
        assertFloatArraysEqual(image.nhwcFloat32(), [1, 128 / 255, 0])
        XCTAssertEqual(image.bgrNCHWFloat32(), [0, 128, 255])
    }

    private func assertFloatArraysEqual(_ values: [Float], _ expected: [Float]) {
        XCTAssertEqual(values.count, expected.count)
        for (a, b) in zip(values, expected) { XCTAssertEqual(a, b, accuracy: 0.0001) }
    }
}
