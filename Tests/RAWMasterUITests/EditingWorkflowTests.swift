import AppKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import RAWMasterCore
import RAWMasterImaging
import RAWMasterAI
@testable import RAWMaster

final class EditingWorkflowTests: XCTestCase {
    struct Fixture {
        let root: URL, library: URL, store: LibraryStore, defaults: UserDefaults
        let assets: [AssetRecord]
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeEditing-" + UUID().uuidString)
            library = root.appendingPathComponent("library.sqlite")
            let originals = root.appendingPathComponent("originals")
            try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
            store = try LibraryStore(databaseURL: library)
            let project = ProjectRecord(name: "Native Editing QA"); try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: originals.path, mode: .reference, status: "completed", discovered: 2, completed: 2, scanCompleted: true)
            try store.saveSession(session)
            var registered: [AssetRecord] = []
            for index in 0..<2 {
                let url = originals.appendingPathComponent("QA-\(index).png")
                let context = CGContext(data: nil, width: 120, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.setFillColor(CGColor(red: index == 0 ? 0.35 : 0.7, green: 0.4, blue: 0.5, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
                let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
                CGImageDestinationAddImage(destination, context.makeImage()!, nil); XCTAssertTrue(CGImageDestinationFinalize(destination))
                let bytes = try Data(contentsOf: url)
                registered.append(try store.register(.init(sessionID: session.id, projectID: project.id, sourcePath: url.path,
                    fileSize: Int64(bytes.count), contentHash: FileSafety.hash(url), importState: .ready)))
            }
            try store.completedDirectImport(session)
            assets = registered; defaults = UserDefaults(suiteName: "NativeEditing-" + UUID().uuidString)!
        }
        func clean() { try? FileManager.default.removeItem(at: root) }
    }
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        XCTFail("Timed out waiting for editing state", file: file, line: line)
    }
    @MainActor func testSavedDevelopmentIsCandidateUntilExplicitAdoptionAndPreservesOriginal() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        let original = try Data(contentsOf: fixture.assets[0].resolvedURL)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil }
        let first = try XCTUnwrap(controller.work)
        controller.setRecipe { $0.exposureEV = 0.5; $0.crop = .init(x: 0.1, y: 0.1, width: 0.8, height: 0.8) }
        XCTAssertTrue(controller.isDirty); controller.saveDevelopment()
        try await wait { !controller.saving && controller.versions.count == 2 }
        let candidate = try XCTUnwrap(controller.selectedVersion)
        XCTAssertEqual(candidate.kind, .development); XCTAssertEqual(candidate.recipe.exposureEV, 0.5)
        XCTAssertNotNil(candidate.artifact)
        XCTAssertEqual(controller.work?.adoptedVersionID, first.originalVersionID)
        controller.adopt(candidate); try await wait { controller.work?.adoptedVersionID == candidate.id }
        XCTAssertEqual(try Data(contentsOf: fixture.assets[0].resolvedURL), original)
        XCTAssertEqual(try fixture.store.loadAssets().first?.rating, 0)
        XCTAssertTrue(try fixture.store.loadReviewRecords().isEmpty)
        await controller.shutdown()
    }
    @MainActor func testFocusGenerationAndDraftRemainBoundToPhotoWhileBrowsing() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); controller.focus(fixture.assets[1])
        try await wait { controller.work?.source.assetID == fixture.assets[1].id }
        controller.setRecipe { $0.exposureEV = 1.25 }
        controller.focus(fixture.assets[0]); try await wait { controller.work?.source.assetID == fixture.assets[0].id }
        XCTAssertEqual(controller.recipe.exposureEV, 0)
        controller.focus(fixture.assets[1]); try await wait { controller.work?.source.assetID == fixture.assets[1].id }
        XCTAssertEqual(controller.recipe.exposureEV, 1.25); XCTAssertTrue(controller.isDirty)
        await controller.shutdown()
    }
    @MainActor func testAIIntentPrecedesProviderIOAndResultNeverAdoptsAfterPhotoChanges() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil && !controller.profiles.isEmpty }
        let originalWork = try XCTUnwrap(controller.work)
        var profile = try XCTUnwrap(controller.profiles.first(where: { $0.kind == .localComfy }))
        profile.acceptedForUse = true; try await controller.saveProfile(profile, secret: nil); controller.selectedProfileID = profile.id
        let provider = CandidateProvider(store: fixture.store)
        controller.providerOverride = provider
        XCTAssertTrue(controller.canGenerate); controller.generate()
        try await wait { !controller.jobs.isEmpty }
        controller.focus(fixture.assets[1])
        try await wait { controller.jobs.first?.state == .succeeded }
        let persistedIntent = await provider.sawPersistedIntent
        XCTAssertTrue(persistedIntent)
        let resultJob = try XCTUnwrap(controller.jobs.first)
        XCTAssertEqual(resultJob.request.source.assetID, fixture.assets[0].id)
        XCTAssertEqual(resultJob.request.inputArtifact.bitDepth, 8)
        XCTAssertLessThanOrEqual(resultJob.request.inputArtifact.pixelWidth * resultJob.request.inputArtifact.pixelHeight, 1_048_576)
        XCTAssertTrue(resultJob.request.inputArtifact.relativePath.hasPrefix(".inputs/"))
        XCTAssertNotNil(resultJob.resultVersionID)
        XCTAssertEqual(try fixture.store.photoWork(id: originalWork.id).adoptedVersionID, originalWork.originalVersionID)
        XCTAssertEqual(controller.asset?.id, fixture.assets[1].id)
        await controller.shutdown()
    }
    @MainActor func testUnknownProviderOutcomeRequiresExplicitRetryAndDoesNotSubmitAgain() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil && !controller.profiles.isEmpty }
        var profile = try XCTUnwrap(controller.profiles.first(where: { $0.kind == .localComfy }))
        profile.kind = .openAI; profile.id = "fake-cloud"; profile.endpoint = URL(string: "https://example.com/v1/images/edits")!; profile.credentialReference = "fake-reference"; profile.acceptedForUse = true
        try fixture.store.saveProviderProfile(profile); await controller.reloadProfiles(); controller.selectedProfileID = profile.id
        let provider = UnknownProvider(); controller.providerOverride = provider
        controller.generate(); try await wait { controller.jobs.first?.state == .outcomeUnknown }
        let job = try XCTUnwrap(controller.jobs.first)
        controller.retry(job); try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await provider.calls
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try fixture.store.processingJob(id: job.id).attempts.count, 1)
        await controller.shutdown()
    }
    @MainActor func testReceivedAIOutputSurvivesPublicationFailureAndResumesWithoutProviderResubmission() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil && !controller.profiles.isEmpty }
        var profile = try XCTUnwrap(controller.profiles.first(where: { $0.kind == .localComfy }))
        profile.acceptedForUse = true; try await controller.saveProfile(profile, secret: nil); controller.selectedProfileID = profile.id
        let provider = CandidateProvider(store: fixture.store); controller.providerOverride = provider
        controller.archivePublicationHook = { kind in
            if kind == .ai { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError) }
        }
        controller.generate(); try await wait { controller.jobs.first?.state == .outcomeUnknown }
        let interrupted = try XCTUnwrap(controller.jobs.first)
        XCTAssertNotNil(interrupted.currentAttempt.receivedOutput)
        XCTAssertTrue(controller.canResumeSaving(interrupted))
        XCTAssertThrowsError(try fixture.store.retryProcessingJob(id: interrupted.id, allowUnknownOutcome: true))
        controller.archivePublicationHook = nil
        controller.resumeSaving(interrupted); try await wait { controller.jobs.first?.state == .succeeded }
        let calls = await provider.calls; XCTAssertEqual(calls, 1)
        XCTAssertNotNil(controller.jobs.first?.resultVersionID)
        await controller.shutdown()
    }
    @MainActor func testArchivedVersionCanBeOpenedAndExportedWhenOriginalIsOffline() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil }
        controller.setRecipe { $0.exposureEV = 0.5 }; controller.saveDevelopment()
        try await wait { !controller.saving && controller.versions.count == 2 }
        let candidate = try XCTUnwrap(controller.selectedVersion)
        controller.adopt(candidate); try await wait { controller.work?.adoptedVersionID == candidate.id }
        try FileManager.default.removeItem(at: fixture.assets[0].resolvedURL)
        try fixture.store.refreshAvailability(ids: [fixture.assets[0].id])
        let offline = try XCTUnwrap(fixture.store.loadAssets().first { $0.id == fixture.assets[0].id })
        controller.focus(offline)
        try await wait { controller.work != nil && !controller.loading && controller.preview != nil }
        XCTAssertFalse(controller.sourceReady); XCTAssertEqual(controller.stage, .versions)
        XCTAssertEqual(controller.selectedVersionID, candidate.id); XCTAssertFalse(controller.canGenerate)
        let exported = try await controller.exportService.export(work: XCTUnwrap(controller.work), version: candidate, archive: controller.archive,
            destination: fixture.root.appendingPathComponent("offline-adopted.jpg"), format: .jpeg8)
        XCTAssertGreaterThan(exported.artifact.byteCount, 0)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: offline.projectID); model.select(offline); model.setMode(.single)
        try await wait { model.editing?.hasSavedWork(assetID: offline.id) == true }
        XCTAssertTrue(model.canOpenNativeEditing)
        await controller.shutdown(); await model.editing?.shutdown()
    }
    @MainActor func testPendingRenderedExportNeverFollowsDifferentPhotoAfterDelayedFocus() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        let slowID = fixture.assets[0].id
        controller.focusSnapshotHook = { id in if id == slowID { Thread.sleep(forTimeInterval: 0.15) } }
        controller.prepareExport(asset: fixture.assets[0]); controller.focus(fixture.assets[1])
        try await wait { controller.work?.source.assetID == fixture.assets[1].id }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(controller.showExport); XCTAssertNil(controller.exportVersionID)
        await controller.shutdown()
    }
    @MainActor func testShutdownCannotStartQueuedLocalGeneration() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil && !controller.profiles.isEmpty }
        var profile = try XCTUnwrap(controller.profiles.first { $0.kind == .localComfy })
        profile.acceptedForUse = true; try await controller.saveProfile(profile, secret: nil); controller.selectedProfileID = profile.id
        let provider = BlockingProvider(); controller.providerOverride = provider
        controller.generate(); try await wait { controller.jobs.first?.state == .running && !controller.saving }
        controller.generate(); try await wait { controller.jobs.count == 2 && controller.jobs.contains { $0.state == .queued } }
        let queued = try XCTUnwrap(controller.jobs.first { $0.state == .queued })
        await controller.shutdown(); try await Task.sleep(nanoseconds: 100_000_000)
        let calls = await provider.calls; XCTAssertEqual(calls, 1)
        XCTAssertNil(try fixture.store.processingJob(id: queued.id).currentAttempt.submissionIntentAt)
        XCTAssertFalse(controller.canGenerate)
    }
    @MainActor func testRenderedExportAssociationPersistsAndMissingTargetDoesNotRerender() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        controller.focus(fixture.assets[0]); try await wait { controller.work != nil }
        controller.setRecipe { $0.exposureEV = 0.25 }; controller.saveDevelopment()
        try await wait { !controller.saving && controller.versions.count == 2 }
        let version = try XCTUnwrap(controller.selectedVersion)
        let output = fixture.root.appendingPathComponent("delivered.jpg")
        let rendered = try await controller.exportVersion(version, destination: output, format: .jpeg8)
        let receipt = try XCTUnwrap(controller.renderedExports.first)
        XCTAssertEqual(receipt.state, .succeeded); XCTAssertEqual(receipt.versionID, version.id)
        XCTAssertEqual(receipt.preparedArtifact?.sha256, rendered.artifact.sha256)
        await controller.shutdown()
        try FileManager.default.removeItem(at: output)
        let reopened = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        await reopened.refreshRenderedExports(reconcile: true)
        let recovered = try XCTUnwrap(reopened.renderedExports.first)
        XCTAssertEqual(recovered.id, receipt.id); XCTAssertEqual(recovered.versionID, version.id)
        XCTAssertEqual(recovered.state, .needsAttention)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path), "Reconciliation cannot generate or replace external exports")
        await reopened.shutdown()
    }
    @MainActor func testShutdownCancelsAndJoinsRuntimeActionBeforeReturning() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let controller = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults)
        let operation = ControlledRuntimeAction()
        controller.runtimeActionOverride = { try await operation.run() }
        controller.startRuntime()
        for _ in 0..<100 { if await operation.started { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let started = await operation.started; XCTAssertTrue(started)
        var quitReturned = false
        let quit = Task { await controller.shutdown(); quitReturned = true }
        for _ in 0..<100 { if await operation.cancellationObserved { break }; try await Task.sleep(nanoseconds: 10_000_000) }
        let cancelled = await operation.cancellationObserved; XCTAssertTrue(cancelled)
        XCTAssertFalse(quitReturned, "Shutdown must await installer/rollback child joining")
        XCTAssertTrue(controller.runtimeBusy)
        await operation.releaseJoin()
        await quit.value
        let joined = await operation.joined; XCTAssertTrue(joined)
        XCTAssertTrue(quitReturned); XCTAssertFalse(controller.runtimeBusy)
        controller.startRuntime()
        let calls = await operation.calls; XCTAssertEqual(calls, 1, "Termination forbids a new runtime action")
    }
    @MainActor func testNativeEntryAndSheetsDoNotChangeExistingBusyOrOriginalExportContext() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: fixture.assets[0].projectID); model.select(fixture.assets[0]); model.setMode(.single)
        XCTAssertTrue(model.canOpenNativeEditing); model.openNativeEditing()
        XCTAssertTrue(model.isNativeEditing); XCTAssertFalse(model.isBusy)
        model.openPhotoExport(); XCTAssertEqual(model.workbenchExportContext, .photo(id: fixture.assets[0].id))
        model.showExport = false; model.editing?.showJobs = true
        XCTAssertTrue(model.hasBusinessSheet)
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)!
        XCTAssertFalse(model.handleKey(key))
        await model.editing?.shutdown()
    }
    @MainActor func testAdmittedPhotoOpensNativeEditingFromLibraryAndImportHistory() async throws {
        let fixture = try Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.all); model.select(fixture.assets[0]); model.setMode(.single)
        XCTAssertTrue(model.canOpenNativeEditing)
        model.openNativeEditing()
        XCTAssertTrue(model.isNativeEditing)
        XCTAssertEqual(model.scope, .all)
        model.returnFromNativeEditing()
        XCTAssertEqual(model.scope, .all)
        model.selectScope(.session, id: fixture.assets[0].sessionID)
        model.select(fixture.assets[0]); model.setMode(.single)
        XCTAssertTrue(model.canOpenNativeEditing)
        model.openNativeEditing()
        XCTAssertTrue(model.isNativeEditing)
        XCTAssertEqual(model.scope, .session)
        model.setMode(.grid)
        XCTAssertFalse(model.canOpenNativeEditing)
        await model.editing?.shutdown()
    }
}

private actor CandidateProvider: AIEditingProvider {
    let store: LibraryStore
    private(set) var sawPersistedIntent = false
    private(set) var calls = 0
    init(store: LibraryStore) { self.store = store }
    func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
        calls += 1
        let persisted = try store.loadProcessingJobs().first { $0.currentAttempt.id == attempt.id }
        sawPersistedIntent = persisted?.state == .submitting && persisted?.currentAttempt.submissionIntentAt != nil
        progress(.init(state: .running, remoteID: "fixture-result"))
        try await Task.sleep(nanoseconds: 150_000_000)
        return .init(fileURL: request.inputFileURL, artifact: request.inputArtifact, configuration: ["fixture": "true"], remoteID: "fixture-result")
    }
    func cancel(attempt: ProcessingAttempt) async throws {}
    func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult { .unknown }
}
private actor UnknownProvider: AIEditingProvider {
    private(set) var calls = 0
    func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput { calls += 1; throw AIServiceError.outcomeUnknown }
    func cancel(attempt: ProcessingAttempt) async throws { throw AIServiceError.outcomeUnknown }
    func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult { .unknown }
}

private actor BlockingProvider: AIEditingProvider {
    private(set) var calls = 0
    func edit(_ request: AIEditRequest, attempt: ProcessingAttempt, progress: @escaping @Sendable (AIEditProgress) -> Void) async throws -> AIEditOutput {
        calls += 1; progress(.init(state: .running, remoteID: "blocked-fixture"))
        try await Task.sleep(nanoseconds: 5_000_000_000)
        throw CancellationError()
    }
    func cancel(attempt: ProcessingAttempt) async throws {}
    func reconcile(_ request: AIEditRequest, attempt: ProcessingAttempt) async throws -> AIReconciliationResult { .unknown }
}

private actor ControlledRuntimeAction {
    private(set) var started = false
    private(set) var cancellationObserved = false
    private(set) var joined = false
    private(set) var calls = 0
    private var joinWaiter: CheckedContinuation<Void, Never>?
    func run() async throws {
        started = true; calls += 1
        do { try await Task.sleep(nanoseconds: 60_000_000_000) }
        catch {
            cancellationObserved = true
            await withCheckedContinuation { continuation in joinWaiter = continuation }
            joined = true
            throw error
        }
    }
    func releaseJoin() { joinWaiter?.resume(); joinWaiter = nil }
}
