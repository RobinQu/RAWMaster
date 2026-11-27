import AppKit
import Foundation
import XCTest
import RAWMasterCore
import RAWMasterAI
@testable import RAWMaster

final class LocalLibraryTaskTests: XCTestCase {
    @MainActor func testImportPauseKeepsCheckpointAndContinuesOnReopen() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let original = try await fixture.populate(count: 5)
        let incoming = fixture.root.appending(path: "another card")
        let managed = fixture.root.appending(path: "managed")
        let fm = FileManager.default
        try fm.createDirectory(at: incoming, withIntermediateDirectories: false)
        for asset in try fixture.store.loadAssets(sessionID: original.id) {
            try fm.copyItem(at: asset.resolvedURL, to: incoming.appending(path: asset.filename))
        }

        let service = ImportService(store: fixture.store)
        let paused = try await service.importDirectory(source: incoming, destination: managed, projectName: "Paused",
                                                        mode: .copy, initialScreening: true) { progress in
            if progress.title == "扫描素材" { service.pause() }
        }
        XCTAssertEqual(paused.status, "paused")
        let recorded = try fixture.store.loadAssets(sessionID: paused.id)
        XCTAssertFalse(recorded.isEmpty)
        let other = try AppModelTests.Fixture(); defer { other.clean() }
        let currentRows = try await WorkbenchActivityTask.catalog(fixture.library, store: fixture.store)
        let unrelatedRows = try await WorkbenchActivityTask.catalog(other.library, store: other.store)
        XCTAssertTrue(currentRows.contains { $0.detail == .intake(paused.id) && $0.status.contains("已暂停") })
        XCTAssertFalse(unrelatedRows.contains { $0.detail == .intake(paused.id) })

        let reopened = try LibraryStore(databaseURL: fixture.library)
        let resuming = ImportService(store: reopened)
        for (directory, replacementMessage) in [(incoming, "来源目录"), (managed, "复制目标目录")] {
            let displaced = directory.appendingPathExtension("displaced")
            try fm.moveItem(at: directory, to: displaced)
            try fm.createDirectory(at: directory, withIntermediateDirectories: false)
            try Data([1, 2, 3]).write(to: directory.appending(path: "foreign.jpg"))
            do {
                _ = try await resuming.resume(sessionID: paused.id) { _ in }
                XCTFail("A different directory occupied the saved location")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(replacementMessage), error.localizedDescription)
            }
            XCTAssertEqual(try fm.contentsOfDirectory(atPath: directory.path), ["foreign.jpg"])
            XCTAssertEqual(try reopened.loadAssets(sessionID: paused.id).map(\.id), recorded.map(\.id))
            try fm.removeItem(at: directory)
            try fm.moveItem(at: displaced, to: directory)
        }
        let finished = try await resuming.resume(sessionID: paused.id) { _ in }
        XCTAssertEqual(finished.id, paused.id)
        XCTAssertEqual(finished.status, "completed")
        let result = try reopened.loadAssets(sessionID: paused.id)
        XCTAssertEqual(result.count, 5)
        XCTAssertTrue(Set(recorded.map(\.id)).isSubset(of: Set(result.map(\.id))))
    }

    @MainActor func testChangingLibrariesPausesPendingBatchAndUserCanCancelItAfterReopening() async throws {
        let fixture = try ProjectReviewUITests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate("Batch", filenames: ["Donor.ARW", "Target.ARW"])
        let assets = try fixture.store.loadAssets()
        let donor = try XCTUnwrap(assets.first { $0.filename == "Donor.ARW" })
        let target = try XCTUnwrap(assets.first { $0.filename == "Target.ARW" })
        let batch = try fixture.store.reviewSceneWorkflow(donorID: donor.id, targets: [target.id],
                                                           work: .exposure(0.5), basis: .original)
        let id = batch.header.id
        XCTAssertEqual(batch.items.map(\.state), [.pending])
        let book = SceneWorkflowBatchCoordinator()
        book.start(batch, in: fixture.store)
        await book.stopAndJoin()
        XCTAssertFalse(book.running)
        XCTAssertFalse(book.accepting)

        let reopened = try LibraryStore(databaseURL: fixture.library)
        let check = try reopened.sceneWorkflow(id: id)
        XCTAssertEqual(check.items.map(\.state), [.pending])
        let rows = try await WorkbenchActivityTask.catalog(fixture.library, store: reopened)
        XCTAssertTrue(rows.contains { $0.detail == .workflow(id) && $0.status.contains("已暂停") })

        let afterOpen = SceneWorkflowBatchCoordinator()
        afterOpen.cancel(id, in: reopened)
        await afterOpen.stopAndJoin()
        XCTAssertEqual(try reopened.sceneWorkflow(id: id).items.map(\.state), [.cancelled])
    }

    @MainActor func testLibraryRebindingRetainsDeviceTaskAndLoadsOnlyNewLibraryProfiles() async throws {
        let a = try AppModelTests.Fixture(); defer { a.clean() }
        let b = try AppModelTests.Fixture(); defer { b.clean() }
        var profile = try XCTUnwrap(ProviderCatalog.examples.first)
        profile.displayName = "Only in library A"
        try a.store.saveProviderProfile(profile)
        let owner = ApplicationEditingServices(store: a.store, libraryURL: a.library, defaults: a.defaults)
        await owner.reloadProfiles()
        XCTAssertTrue(owner.profiles.contains { $0.displayName == "Only in library A" })

        let model = owner.fluxModel
        owner.runtimeActionOverride = { try await Task.sleep(for: .seconds(60)) }
        owner.performRuntimeAction { _ in }
        await owner.releaseLibrary()
        owner.bindLibrary(store: b.store, libraryURL: b.library)
        await owner.reloadProfiles()
        XCTAssertTrue(owner.actionBusy)
        XCTAssertTrue(owner.fluxModel === model)
        XCTAssertFalse(owner.profiles.contains { $0.displayName == "Only in library A" })
        await owner.shutdown()
    }

    @MainActor func testOptInFluxReconcilesAfterSwitchAndRetriesFrozenInput() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let weights = environment["RAWMASTER_042_FLUX_WEIGHTS"], let input = environment["RAWMASTER_042_FLUX_INPUT"] else {
            throw XCTSkip("Set the locally installed FLUX weights and authorized image fixture")
        }
        _ = NSApplication.shared
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let original = try LocalLibraryPackage.create(at: fixture.root.appending(path: "Generation"))
        let other = try LocalLibraryPackage.create(at: fixture.root.appending(path: "Empty"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: input), to: fixture.source.appending(path: "lake.png"))
        let database = try LibraryStore(databaseURL: original.database)
        _ = try await ImportService(store: database).importDirectory(source: fixture.source, destination: nil,
            projectName: "Local FLUX", mode: .reference) { _ in }
        let asset = try XCTUnwrap(database.loadAssets().first)
        var profile = QuickPromptModel.flux.defaultProfile
        profile.acceptedForUse = true
        profile.configuration["weightsDirectory"] = weights
        try LocalFluxProvider.validateConfiguration(profile)
        try database.saveProviderProfile(profile)

        let session = ApplicationLibrarySession(defaults: fixture.defaults, explicitURL: nil, legacyURL: fixture.library,
                                                confirmSwitch: { _ in .pause })
        session.start(finderURLs: [original.root])
        await session.awaitTransition()
        try await wait { session.model.editing != nil }
        let editor = try XCTUnwrap(session.model.editing)
        editor.isPresented = true
        editor.focus(asset)
        try await wait { editor.sourceReady && editor.profiles.contains { $0.id == profile.id } }
        let work = try XCTUnwrap(editor.work)
        editor.stage = .versions
        editor.openQuickPrompt()
        editor.quickPromptDraft.prompt = "Remove the red stop sign from the lake and restore its background."
        editor.setQuickPromptScope(.rectangle(.init(x: 480.0 / 1024, y: 496.0 / 1024, width: 0.5, height: 0.5)))
        editor.prepareQuickPrompt()
        try await wait(seconds: 120) { editor.jobs.first?.state == .running }
        let started = try XCTUnwrap(editor.jobs.first)
        XCTAssertNotNil(started.currentAttempt.submissionIntentAt)

        session.open(other.root)
        await session.awaitTransition()
        XCTAssertEqual(session.activePackage?.libraryID, other.libraryID, session.openError ?? "")
        let emptyRows = try await WorkbenchActivityTask.catalog(other.database, store: session.model.store)
        XCTAssertFalse(emptyRows.contains { $0.detail == .ai(started.id) })
        session.open(original.root)
        await session.awaitTransition()
        try await wait { session.model.editing?.jobs.first?.state == .outcomeUnknown }
        let resumed = try XCTUnwrap(session.model.editing)
        let interrupted = try XCTUnwrap(resumed.jobs.first)
        XCTAssertEqual(interrupted.state, .outcomeUnknown)
        resumed.reconcile(interrupted)
        try await wait { resumed.jobs.first?.state == .failed || resumed.jobs.first?.state == .succeeded }

        if let verified = resumed.jobs.first, verified.state == .failed {
            resumed.retry(verified)
            try await wait(seconds: 600) { resumed.jobs.first?.state == .succeeded }
        }
        let completed = try XCTUnwrap(resumed.jobs.first)
        XCTAssertEqual(completed.id, started.id)
        XCTAssertEqual(completed.requestFingerprint, started.requestFingerprint)
        XCTAssertEqual(completed.request.inputArtifact.sha256, started.request.inputArtifact.sha256)
        XCTAssertNil(completed.currentAttempt.remoteID)
        let candidate = try database.editingVersion(id: XCTUnwrap(completed.resultVersionID))
        XCTAssertEqual(candidate.kind, .ai)
        let archive = try database.editingArchive()
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: try archive.artifactURL(XCTUnwrap(candidate.artifact)).path))
        XCTAssertEqual(try database.photoWork(id: work.id).adoptedVersionID, work.originalVersionID)
        await session.finishPendingOpenForTermination()
        await session.model.quiesceLocalLibraryTasksForSwitch()
        await session.model.closeLibraryReads()
        await resumed.shutdown()
        await session.model.editingServices?.shutdown()
        session.releaseWriterForTermination()
    }

    @MainActor private func wait(seconds: Double = 15, until predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !predicate() {
            guard Date() < deadline else { throw LibraryError.invalid("等待本机任务状态超时") }
            try await Task.sleep(for: .milliseconds(25))
        }
    }
}
