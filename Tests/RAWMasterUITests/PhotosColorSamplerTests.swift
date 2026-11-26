import AppKit
import XCTest
@testable import RAWMaster
import RAWMasterCore
import RAWMasterImaging

final class PhotosColorSamplerTests: XCTestCase {
    @MainActor func testNinePositionsPersistByPhotoAndEditingThemDoesNotChangeTheRecipe() async throws {
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        let admissionDeadline = ContinuousClock.now + .seconds(20)
        while editing.developmentContext == nil, ContinuousClock.now < admissionDeadline {
            if editing.work != nil { editing.beginDevelopmentInterface() }
            try await Task.sleep(for: .milliseconds(10))
        }
        let context = try XCTUnwrap(editing.developmentContext,
            "Source admission: ready=\(editing.sourceReady), inspectable=\(editing.previews.primary.canInspectDevelopmentSource), presented=\(editing.isPresented), stage=\(editing.stage), preview=\(editing.previews.primary.error ?? "none"), message=\(editing.message ?? "none")"), original = editing.recipe
        func pick(_ point: DevelopmentSourcePoint, replacing index: Int? = nil) async throws {
            for _ in 0..<500 where editing.developmentPicker == nil {
                editing.beginDevelopmentPicker(.colorSampler(replacing: index), context: context)
                if editing.developmentPicker == nil { try await Task.sleep(for: .milliseconds(10)) }
            }
            let picker = try XCTUnwrap(editing.developmentPicker)
            let frame = try XCTUnwrap(editing.developmentPickerFrame(for: picker))
            editing.pickDevelopmentSource(point, frame: frame)
        }
        for i in 1...9 { try await pick(.init(x: Double(i) / 10, y: 0.5)) }
        let store = editing.colorSamplers
        XCTAssertEqual(store.points.count, 9)
        XCTAssertFalse(store.place(.init(x: 0, y: 0)))
        try await pick(.init(x: 0.2, y: 0.8), replacing: 0)
        store.remove(1)
        XCTAssertEqual(store.points.count, 8)
        XCTAssertEqual(store.points[0].y, 0.8, accuracy: 1e-6)
        let display = try XCTUnwrap(try editing.presentedSamplerMapping?.outputPoint(fromSource: store.points[0]))
        XCTAssertEqual(display.x, 0.2, accuracy: 1e-6)
        XCTAssertEqual(editing.recipe, original)
        XCTAssertFalse(editing.developmentSession.canUndo)
        let reopened = PhotosColorSamplers(defaults: fixture.defaults)
        reopened.bind(workID: context.workID, sourceID: context.sourceContentID)
        XCTAssertEqual(reopened.points, store.points)
        reopened.bind(workID: context.workID, sourceID: "different")
        XCTAssertTrue(reopened.points.isEmpty)
        await editing.shutdown()
    }
}
