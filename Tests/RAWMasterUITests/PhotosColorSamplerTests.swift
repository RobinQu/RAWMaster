import AppKit
import XCTest
@testable import RAWMaster
import RAWMasterCore
import RAWMasterImaging

final class PhotosColorSamplerTests: XCTestCase {
    @MainActor func testRealHDRSamplerFollowsPublishedFrameROIAndDiagnosticGeneration() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
            throw XCTSkip("Requires the fixed 24 MP snow ARW")
        }
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let db = root.appending(path: "library.sqlite")
        let asset = try NativePresentedCanvasTests.register(source: URL(fileURLWithPath: path), library: db)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let editor = try EditingController(store: LibraryStore(databaseURL: db), libraryURL: db, defaults: defaults)
        @MainActor func wait(_ condition: () -> Bool) async throws {
            let deadline = ContinuousClock.now + .seconds(35)
            while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            guard condition() else { throw EditingError.commandConflict }
        }
        do {
            editor.isPresented = true; editor.focus(asset)
            try await wait { editor.sourceReady && !editor.loading }
            editor.beginDevelopmentInterface()
            editor.enterSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket))
            try await wait { !editor.sceneStarting && editor.developmentContext != nil && editor.recipe.sceneGraph != nil }
            editor.setSceneDisplay(.init(id: 1, colorProfile: nil, headroom: 2, potentialHeadroom: 2))
            editor.setSceneExposure(2, node: try XCTUnwrap(editor.recipe.sceneGraph?.graph.nodes.first?.id),
                                    ticket: try XCTUnwrap(editor.sceneTicket))
            editor.setSceneSampling(.fit(maximumEdge: 960))
            XCTAssertNil(editor.sceneSamplerFrame)
            try await wait { editor.sceneSamplerFrame != nil }
            let point = DevelopmentSourcePoint(x: 0.37890625, y: 0.3703125)
            let frame = try XCTUnwrap(editor.sceneSamplerFrame)
            let actual = try XCTUnwrap(DevelopmentDisplayPixel.linearSamples(frame, at: [point])[0])
            XCTAssertEqual(actual.target, .hdr2020)
            XCTAssertEqual(actual.luminanceNits, 45.72, accuracy: 0.75)
            let context = try XCTUnwrap(editor.developmentContext)
            editor.beginDevelopmentPicker(.colorSampler(replacing: nil), context: context)
            try XCTUnwrap(editor.scenePhotographicPickHandler)(.init(x: point.x, y: point.y))
            XCTAssertEqual(editor.colorSamplers.points, [point])
            let roi = CGRect(x: 0.37, y: 0.36, width: 0.03, height: 0.03)
            editor.setSceneSampling(.pixels(window: roi))
            XCTAssertNil(editor.sceneSamplerFrame)
            try await wait { editor.sceneSamplerFrame?.window != nil }
            let native = try XCTUnwrap(editor.sceneSamplerFrame)
            XCTAssertNotEqual(frame.id, native.id)
            XCTAssertNotNil(DevelopmentDisplayPixel.linearSamples(native, at: [point])[0])
            editor.beginDevelopmentPicker(.colorSampler(replacing: 0), context: context)
            let repick = try XCTUnwrap(editor.scenePhotographicPickHandler)
            repick(.init(x: 0.9, y: 0.8))
            XCTAssertEqual(editor.colorSamplers.points, [point])
            repick(.init(x: 0.38, y: 0.37))
            XCTAssertEqual(editor.colorSamplers.points, [.init(x: 0.38, y: 0.37)])
            editor.setSceneVisualizeHDR(true)
            try await wait { !editor.scenePreviewBusy && editor.sceneFrame != nil }
            XCTAssertNil(editor.sceneSamplerFrame)
            editor.setSceneViewingHDR(false)
            try await wait { editor.sceneSamplerFrame?.target == .sdr709 }
            XCTAssertNotEqual(editor.sceneSamplerFrame?.id, native.id)
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }

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
