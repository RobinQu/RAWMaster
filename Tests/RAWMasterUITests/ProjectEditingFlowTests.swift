import AppKit
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class ProjectEditingFlowTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Timed out waiting for project editing fixture")
    }
    @MainActor func testEditingRequiresAdmissionReadinessAndPhotoBrowsingContext() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        try f.store.createGroup(ids: f.assets.map(\.id), name: "Project sequence", kind: "连拍")
        let group = try XCTUnwrap(f.store.loadGroups().first)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0])
        XCTAssertTrue(model.canOpenNativeEditing)
        for scope in [AppModel.Scope.all, .session] {
            model.selectScope(scope, id: scope == .session ? f.assets[0].sessionID : "")
            model.mode = .single; model.focusedID = f.assets[0].id
            XCTAssertTrue(model.canOpenNativeEditing, "An admitted photo remains editable in this browsing scope: \(scope)")
            model.openNativeEditing(); XCTAssertTrue(model.editing?.isPresented == true)
            model.returnFromNativeEditing()
        }
        for scope in [AppModel.Scope.imports, .sequences] {
            model.selectScope(scope)
            model.mode = .single; model.focusedID = f.assets[0].id
            XCTAssertFalse(model.canOpenNativeEditing, "Catalog views cannot substitute for a photo browsing scope: \(scope)")
            model.openNativeEditing(); XCTAssertFalse(model.editing?.isPresented == true)
        }
        model.selectScope(.group, id: group.id); model.setMode(.single); model.select(f.assets[0])
        XCTAssertTrue(model.canOpenNativeEditing)
        model.groups[0].projectID = "different-project"
        XCTAssertFalse(model.canOpenNativeEditing)
        model.groups = [group]
        model.assets[0].importState = .discovered
        XCTAssertFalse(model.canOpenNativeEditing, "A source must be ready even when admitted")
        model.assets = f.assets
        model.admissions = []
        XCTAssertFalse(model.canOpenNativeEditing, "A capture/group membership cannot substitute for admission")
        await model.editing?.shutdown()
    }
    @MainActor func testScopeExitInvalidatesDelayedFocusAndPendingExportButRetainsDraft() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0])
        let editing = try XCTUnwrap(model.editing)
        editing.focusSnapshotHook = { _ in Thread.sleep(forTimeInterval: 0.15) }
        model.openRenderedPhotoExport()
        model.selectScope(.all)
        try await Task.sleep(nanoseconds: 250_000_000)
        XCTAssertFalse(editing.isPresented); XCTAssertFalse(editing.showExport)
        XCTAssertFalse(editing.showDraftExportChoice); XCTAssertNil(editing.asset); XCTAssertNil(editing.work)
        editing.focusSnapshotHook = nil
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0]); model.openNativeEditing()
        try await wait { editing.work != nil }
        editing.setRecipe { $0.exposureEV = 0.7 }
        model.returnFromNativeEditing()
        XCTAssertFalse(editing.isPresented); XCTAssertTrue(model.showInspector)
        model.openNativeEditing(); try await wait { editing.work != nil }
        XCTAssertEqual(editing.recipe.exposureEV, 0.7, "Returning to browsing retains the per-photo draft")
        await editing.shutdown()
    }
    @MainActor func testAdmissionRemovalInvalidatesExistingEditorContext() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0]); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing); try await wait { editing.work != nil }
        editing.setRecipe { $0.exposureEV = 0.4 }; model.openRenderedPhotoExport()
        XCTAssertFalse(editing.showDraftExportChoice); XCTAssertFalse(editing.showExport); XCTAssertTrue(model.exportWorkspacePresented)
        XCTAssertEqual(editing.exportVersion?.recipe.exposureEV, 0.4)
        model.admissions.removeAll { $0.assetID == f.assets[0].id }
        XCTAssertFalse(model.canOpenNativeEditing); XCTAssertFalse(editing.isPresented)
        XCTAssertFalse(editing.showDraftExportChoice); XCTAssertNil(editing.asset)
        XCTAssertFalse(editing.showExport); XCTAssertFalse(editing.saving)
        await editing.shutdown()
    }
    @MainActor func testSamePhotoAdmissionReplacementInvalidatesIdentityAndOfflineCache() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0]); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing); try await wait { editing.work != nil }
        let firstWork = try XCTUnwrap(editing.work)
        editing.setRecipe { $0.exposureEV = 0.8 }; model.openRenderedPhotoExport()
        var admission = try XCTUnwrap(model.admissions.first { $0.assetID == f.assets[0].id })
        for changesDate in [true, false] {
            let priorID = try XCTUnwrap(editing.work?.id)
            if changesDate { admission.admittedAt = admission.admittedAt.addingTimeInterval(1) }
            else { admission.sequenceOnly.toggle() }
            let json = String(decoding: try JSONEncoder().encode(admission), as: UTF8.self)
            try f.store.locked { try f.store.statement("UPDATE project_admissions SET data=? WHERE asset_id=?", [json, admission.assetID]) }
            model.admissions = try f.store.loadAdmissions()
            XCTAssertFalse(editing.isPresented); XCTAssertNil(editing.work); XCTAssertNil(editing.asset)
            XCTAssertFalse(editing.showDraftExportChoice)
            model.assets[0].availability = .missing
            XCTAssertFalse(model.canOpenNativeEditing, "An archive from an older admission is not the current photo work")
            model.assets = f.assets
            model.openNativeEditing(); try await wait { editing.work != nil }
            XCTAssertNotEqual(editing.work?.id, priorID)
            XCTAssertNotEqual(editing.work?.source.admissionFingerprint, firstWork.source.admissionFingerprint)
            XCTAssertEqual(editing.recipe.exposureEV, 0, "A previous admission's draft must not transfer")
        }
        let stableID = editing.work?.id
        model.assets[0].rating = 4
        XCTAssertEqual(editing.work?.id, stableID, "Catalogue annotations do not change editing identity")
        XCTAssertTrue(editing.isPresented)
        await editing.shutdown()
    }
    @MainActor func testLiveExportUsesCurrentRecipeWithoutSavingOrAdoptingACandidate() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0]); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing); try await wait { editing.work != nil }
        let original = try XCTUnwrap(editing.work?.originalVersionID)
        editing.setRecipe { $0.exposureEV = 0.5 }
        model.openRenderedPhotoExport()
        XCTAssertFalse(editing.showDraftExportChoice); XCTAssertFalse(editing.showExport); XCTAssertTrue(model.exportWorkspacePresented)
        XCTAssertEqual(editing.exportVersionID, original)
        XCTAssertEqual(editing.exportVersion?.recipe.exposureEV, 0.5)
        XCTAssertEqual(editing.versions.count, 1)
        XCTAssertEqual(editing.work?.adoptedVersionID, original)
        XCTAssertFalse(editing.saving)
        await editing.shutdown()
    }
    @MainActor func testLeavingProjectKeepsAlreadySubmittedAIJobAndUnadoptedResult() async throws {
        let f = try EditingWorkflowTests.Fixture(); defer { f.clean() }
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.selectScope(.project, id: f.assets[0].projectID); model.setMode(.single); model.select(f.assets[0]); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing); try await wait { editing.work != nil && !editing.profiles.isEmpty }
        let work = try XCTUnwrap(editing.work)
        var profile = try XCTUnwrap(editing.profiles.first { $0.kind == .localComfy })
        profile.acceptedForUse = true; try await editing.saveProfile(profile, secret: nil); editing.selectedProfileID = profile.id
        editing.providerOverride = ProjectFlowCandidateProvider()
        editing.stage = .ai; editing.generate()
        try await wait { editing.jobs.first?.state == .running }
        model.selectScope(.all)
        XCTAssertFalse(editing.isPresented); XCTAssertNil(editing.asset)
        try await wait { editing.jobs.first?.state == .succeeded }
        XCTAssertNotNil(editing.jobs.first?.resultVersionID)
        XCTAssertEqual(try f.store.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
        XCTAssertNil(editing.asset, "A completed background job must not reopen the departed project editor")
        await editing.shutdown()
    }
}
private actor ProjectFlowCandidateProvider: AIEditingProvider {
    func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
        progress(.init(state: .running))
        try await Task.sleep(nanoseconds: 150_000_000)
        return .init(fileURL: request.inputFileURL, artifact: request.inputArtifact, configuration: ["fixture": "project-flow"])
    }
    func cancel(attempt: ProcessingAttempt) async throws {}
    func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult { .unknown }
}
