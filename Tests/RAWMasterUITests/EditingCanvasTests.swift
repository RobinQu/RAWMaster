import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster
@testable import RAWMasterImaging

final class EditingCanvasTests: XCTestCase {
    @MainActor func testInitialDevelopmentDraftTitleAndAdoptionTargetDoNotDescribeAdoptedAIPixels() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil && !controller.profiles.isEmpty }
        var profile = try XCTUnwrap(controller.profiles.first { $0.kind == .localComfy })
        profile.acceptedForUse = true; try await controller.saveProfile(profile, secret: nil); controller.selectedProfileID = profile.id
        controller.providerOverride = CanvasCandidateProvider()
        controller.stage = .versions; controller.generate()
        try await wait { controller.jobs.first?.state == .succeeded }
        let id = try XCTUnwrap(controller.jobs.first?.resultVersionID)
        try await wait { controller.versions.contains { $0.id == id } }
        let candidate = try XCTUnwrap(controller.versions.first { $0.id == id })
        controller.selectVersion(candidate); controller.adopt(candidate)
        try await wait { controller.work?.adoptedVersionID == candidate.id }
        controller.stage = .development
        XCTAssertEqual(controller.canvasTitle, "当前编辑")
        XCTAssertNil(controller.displayedSavedVersion, "The footer cannot offer adoption of AI pixels while the canvas shows a RAW draft")
        controller.stage = .versions
        XCTAssertEqual(controller.canvasTitle, "AI 候选")
        XCTAssertEqual(controller.displayedSavedVersion?.id, candidate.id)
        controller.stage = .development; controller.saveDevelopment()
        try await wait { !controller.saving && controller.selectedVersion?.kind == .development }
        XCTAssertEqual(controller.canvasTitle, "当前编辑")
        XCTAssertEqual(controller.displayedSavedVersion?.id, controller.selectedVersionID)
        XCTAssertNotEqual(controller.displayedSavedVersion?.id, controller.work?.adoptedVersionID)
        await controller.checkRuntime()
        XCTAssertEqual(controller.runtimeState, "stopped")
        XCTAssertEqual(controller.runtimeStateTitle, "已停止")
        await controller.shutdown()
    }
    @MainActor func testCanvasDoubleClickUsesToolActionInsteadOfChangingZoom() throws {
        let canvas = ImageCanvas(frame: .init(x: 0, y: 0, width: 320, height: 240))
        canvas.update(image: NSImage(size: .init(width: 320, height: 240)), actualPixels: false, transform: .init())
        var completions = 0
        canvas.onDoubleClick = { completions += 1 }
        let event = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .init(x: 100, y: 100),
            modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 2, pressure: 1))
        canvas.mouseDown(with: event)
        XCTAssertEqual(completions, 1)
        XCTAssertNil(canvas.onTransform, "A tool double-click must not publish an actual-pixel zoom")
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Timed out waiting for canvas fixture")
    }
}
private actor CanvasCandidateProvider: AIEditingProvider {
    func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
        progress(.init(state: .running))
        return .init(fileURL: request.inputFileURL, artifact: request.inputArtifact, configuration: ["fixture": "canvas-adoption"])
    }
    func cancel(attempt: ProcessingAttempt) async throws {}
    func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult { .unknown }
}
