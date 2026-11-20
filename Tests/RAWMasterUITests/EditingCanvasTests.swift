import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class EditingCanvasTests: XCTestCase {
    @MainActor func testInitialDevelopmentDraftTitleAndAdoptionTargetDoNotDescribeAdoptedAIPixels() async throws {
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil && !controller.profiles.isEmpty }
        var profile = try XCTUnwrap(controller.profiles.first { $0.kind == .localComfy })
        profile.acceptedForUse = true; try await controller.saveProfile(profile, secret: nil); controller.selectedProfileID = profile.id
        controller.providerOverride = CanvasCandidateProvider()
        controller.stage = .ai; controller.generate()
        try await wait { controller.jobs.first?.state == .succeeded }
        let id = try XCTUnwrap(controller.jobs.first?.resultVersionID)
        try await wait { controller.versions.contains { $0.id == id } }
        let candidate = try XCTUnwrap(controller.versions.first { $0.id == id })
        controller.selectVersion(candidate); controller.adopt(candidate)
        try await wait { controller.work?.adoptedVersionID == candidate.id }
        controller.stage = .development
        XCTAssertEqual(controller.canvasTitle, "原片初修草稿")
        XCTAssertNil(controller.displayedSavedVersion, "The footer cannot offer adoption of AI pixels while the canvas shows a RAW draft")
        controller.stage = .versions
        XCTAssertEqual(controller.canvasTitle, "AI 候选")
        XCTAssertEqual(controller.displayedSavedVersion?.id, candidate.id)
        controller.stage = .development; controller.saveDevelopment()
        try await wait { !controller.saving && controller.selectedVersion?.kind == .development }
        XCTAssertEqual(controller.canvasTitle, "原片初修草稿")
        XCTAssertEqual(controller.displayedSavedVersion?.id, controller.selectedVersionID)
        XCTAssertNotEqual(controller.displayedSavedVersion?.id, controller.work?.adoptedVersionID)
        await controller.checkRuntime()
        XCTAssertEqual(controller.runtimeState, "stopped")
        XCTAssertEqual(controller.runtimeStateTitle, "已停止")
        await controller.shutdown()
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
