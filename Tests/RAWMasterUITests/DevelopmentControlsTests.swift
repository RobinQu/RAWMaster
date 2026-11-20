import AppKit
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class DevelopmentControlsTests: XCTestCase {
    func testNumericDisplayRoundTripsWhiteBalanceWithoutGroupingOrLocaleGuessing() throws {
        let temperature = DevelopmentNumericText.format(10000, fractionDigits: 0)
        XCTAssertEqual(temperature, "10000")
        XCTAssertEqual(DevelopmentNumericText.parse(temperature, range: 2000...50000), 10000)
        XCTAssertEqual(DevelopmentNumericText.format(-12.5, fractionDigits: 3), "-12.5")
        XCTAssertEqual(DevelopmentNumericText.parse("-12.5", range: -100...100), -12.5)
        XCTAssertEqual(DevelopmentNumericText.parse("+.5", range: -100...100), 0.5)
        for text in ["1,000", "10,000", "1.000,0", "1,5", "1 000", "1\u{00a0}000", "1\u{202f}000", "1_000", "NaN", "inf", "1e2", "1.2.3", "-", "", " 1", "1x", "1\n"] {
            XCTAssertNil(DevelopmentNumericText.parse(text, range: -100000...100000), "Full-string decimal contract rejects: \(text)")
        }
        XCTAssertNil(DevelopmentNumericText.parse("1000", range: -100...100))
    }
    @MainActor func testRejectedNumericTextDoesNotMutateOrPromoteAndCorrectedTextIsAccepted() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults)
        let initial = editing.recipe
        for text in ["1,000", "1000", "1,5", "1.2.3"] {
            if let parsed = DevelopmentNumericText.parse(text, range: -100...100) { editing.setTone(.contrast, value: parsed) }
            XCTAssertEqual(editing.recipe, initial)
        }
        let corrected = try XCTUnwrap(DevelopmentNumericText.parse("1.5", range: -100...100))
        editing.setTone(.contrast, value: corrected)
        XCTAssertEqual(editing.developmentColor.tones.contrast, 1.5)
        XCTAssertEqual(editing.recipe.schemaVersion, 2)
        await editing.shutdown()
    }
    @MainActor func testZeroAndSmallFocusMasksAreSafeWithoutAGraphicsContext() {
        for size in [0.0, 1, 4] {
            let control = DevelopmentEditingControl(frame: CGRect(x: 0, y: 0, width: size, height: size))
            control.drawFocusRingMask()
            XCTAssertEqual(control.focusRingMaskBounds.size, CGSize(width: size, height: size))
        }
    }

    @MainActor func testLegacyProjectionAndNoOpResetNeverPromoteOrSchedulePixels() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults)
        let fingerprint = try EditingFingerprint.of(editing.recipe)
        let revision = editing.previews.primary.currentRevision
        _ = editing.developmentColor
        editing.setTone(.contrast, value: 0)
        editing.resetDevelopmentSection(.curves); editing.resetDevelopmentSection(.grading); editing.resetDevelopmentSection(.basic)
        editing.resetRecipe()
        XCTAssertEqual(try EditingFingerprint.of(editing.recipe), fingerprint)
        XCTAssertEqual(editing.recipe.schemaVersion, 1); XCTAssertNil(editing.recipe.color)
        XCTAssertFalse(editing.isDirty); XCTAssertEqual(editing.previews.primary.currentRevision, revision)
        await editing.shutdown()
    }
    @MainActor func testNewColorEditPromotesOnceAndResetsPreserveEngineAndOtherSections() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults)
        editing.setRecipe { $0.exposureEV = 0.5; $0.straightenDegrees = 2 }
        XCTAssertEqual(editing.recipe.schemaVersion, 1)
        editing.setTone(.shadows, value: 35)
        XCTAssertEqual(editing.recipe.schemaVersion, 2); XCTAssertEqual(editing.recipe.engineVersion, "rawmaster-color-v2")
        XCTAssertEqual(editing.recipe.exposureEV, 0.5)
        let curve = DevelopmentCurve(points: [.init(x: 0, y: 0.1), .init(x: 0.4, y: 0.6), .init(x: 1, y: 1)])
        editing.setCurve(.red, curve: curve)
        editing.setGrading(.highlights, wheel: .init(hueDegrees: 45, saturation: 30, luminance: 7), component: "fixture")
        editing.resetDevelopmentSection(.basic)
        XCTAssertEqual(editing.recipe.exposureEV, 0); XCTAssertEqual(editing.recipe.straightenDegrees, 2)
        XCTAssertEqual(editing.developmentColor.curves.red, curve)
        XCTAssertEqual(editing.developmentColor.grading.highlights.saturation, 30)
        editing.resetCurve(.red)
        XCTAssertTrue(editing.developmentColor.curves.isNeutral)
        XCTAssertEqual(editing.developmentColor.grading.highlights.luminance, 7)
        editing.resetRecipe()
        XCTAssertEqual(editing.recipe.schemaVersion, 2); XCTAssertNotNil(editing.recipe.color)
        XCTAssertTrue(editing.developmentColor.isNeutral); XCTAssertEqual(editing.recipe.straightenDegrees, 0)
        await editing.shutdown()
    }
    @MainActor func testInvalidCandidateIsAtomicAndHueCanonicalizationPrecedesCommit() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults)
        let original = editing.recipe
        for value in [Double.nan, .infinity, -101, 101] { editing.setTone(.contrast, value: value); XCTAssertEqual(editing.recipe, original) }
        editing.setCurve(.rgb, curve: .init(points: [.init(x: 0, y: 0), .init(x: 0, y: 0.5), .init(x: 1, y: 1)]))
        XCTAssertEqual(editing.recipe, original)
        editing.setRecipe { $0.crop.width = -1 }
        XCTAssertEqual(editing.recipe, original)
        editing.setGrading(.shadows, wheel: .init(hueDegrees: 360, saturation: 40), component: "hue")
        XCTAssertEqual(editing.developmentColor.grading.shadows.hueDegrees, 0)
        try editing.recipe.validate()
        let valid = editing.recipe
        editing.setGrading(.shadows, wheel: .init(hueDegrees: 361, saturation: 40), component: "hue")
        XCTAssertEqual(editing.recipe, valid)
        await editing.shutdown()
    }
    @MainActor func testSectionDepartureEndsGestureAndKeepsProgrammaticClassification() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let editing = try EditingController(store: f.store, libraryURL: f.library, defaults: f.defaults)
        editing.previewInteractionChanged("curve.R", active: true)
        editing.setCurve(.red, curve: .init(points: [.init(x: 0, y: 0), .init(x: 0.4, y: 0.65), .init(x: 1, y: 1)]))
        XCTAssertTrue(editing.previewInteracting)
        editing.endPreviewInteractions(prefix: "curve.")
        XCTAssertFalse(editing.previewInteracting)
        let input = EditingPreviewInput.capture(control: "tone.contrast", phase: "discrete", nativeEvent: false)
        XCTAssertEqual(input.origin, .programmatic); XCTAssertNil(input.eventAt)
        await editing.shutdown()
    }
}
