import Foundation
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class EditingVirtualCopyContextTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(45)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        guard condition() else { throw EditingError.commandConflict }
    }

    @MainActor func testLateSavePublishesOnlyItsPresentationAfterLeavingTheEditor() async throws {
        let fixture = try EditingWorkflowTests.Fixture(photoCount: 1)
        defer { fixture.clean() }
        let editor = try EditingController(store: fixture.store, libraryURL: fixture.library, defaults: fixture.defaults,
            previewBackend: PhotosDevelopmentBackend())
        let original = fixture.assets[0], gate = PhotosAnalysisGate()
        var saved: [PhotoWork] = []
        editor.didPersistRendition = { saved.append($0) }
        do {
            editor.isPresented = true
            editor.focus(original)
            try await wait { editor.sourceReady && editor.work != nil }
            let master = try XCTUnwrap(editor.work)
            let copy = try fixture.store.createVirtualCopy(of: original, name: "另一份")
            let rendition = copy.projecting(original)
            editor.liveStateCASWillBeginHook = { id, recipe in
                if id == master.id, recipe.exposureEV == 0.875 { await gate.suspend() }
            }
            editor.setRecipe { $0.exposureEV = 0.875 }
            await gate.waitUntilEntered()
            editor.leaveBrowsingContext()
            let joined = Task { try await editor.awaitPendingRenditionWrites(for: original.id) }
            editor.isPresented = true
            editor.focus(rendition)
            try await wait { editor.sourceReady && editor.work?.id == copy.id }
            XCTAssertEqual(editor.recipe.exposureEV, 0)
            editor.setRecipe { $0.exposureEV = -0.625 }
            try await editor.awaitPendingRenditionWrites(for: copy.id)
            XCTAssertEqual(saved.map(\.presentationID), [copy.id])
            await gate.release()
            try await joined.value
            XCTAssertEqual(saved.map(\.presentationID), [copy.id, original.id])
            XCTAssertEqual(try fixture.store.photoWork(id: master.id).liveRecipe?.exposureEV, 0.875)
            XCTAssertEqual(try fixture.store.photoWork(id: copy.id).liveRecipe?.exposureEV, -0.625)
            XCTAssertEqual(editor.work?.id, copy.id)
            XCTAssertEqual(editor.recipe.exposureEV, -0.625)
        } catch { await gate.release(); await editor.shutdown(); throw error }
        await editor.shutdown()
    }

    @MainActor func testArchivedCopyDisplaysItsActualFileAcrossOfflineAndReconnect() async throws {
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        let store = fixture.store, original = fixture.assets[0], editedFile = fixture.assets[1].resolvedURL
        let source = try store.captureEditingSourceSnapshot(assetID: original.id)
        let master = try store.createPhotoWork(source: source)
        let earlier = DevelopmentRecipe(exposureEV: 0.75)
        _ = try store.saveLiveDevelopmentState(workID: master.id, recipe: earlier, parentVersionID: master.originalVersionID,
            expectedRevision: 0, expectedAdoptionRevision: master.adoptionRevision)
        let archive = try EditingController.openArchive(store: store, libraryURL: fixture.library)
        let pixels = try PhotoRenderer.inspect(editedFile)
        XCTAssertNotEqual(pixels.sha256, source.contentSHA256)
        let external = EditingVersion(workID: master.id, parentVersionID: master.originalVersionID, kind: .external,
            source: source, artifact: pixels)
        let registered = try store.commitArchivePublication(archive.publish(fileURL: editedFile, version: external))
        _ = try store.adoptEditingVersion(workID: master.id, versionID: registered.id, expectedRevision: master.adoptionRevision)
        let chosen = try store.photoWork(id: master.id)
        XCTAssertEqual(chosen.liveRecipe, earlier)
        XCTAssertFalse(chosen.usesLiveRendition(over: registered))
        XCTAssertThrowsError(try store.saveLiveDevelopmentState(workID: master.id, recipe: .init(exposureEV: 3),
            parentVersionID: master.originalVersionID, expectedRevision: 1, expectedAdoptionRevision: master.adoptionRevision))
        let oldSelection = try AppModel.storedWorkbenchInput(original, fingerprint: source.admissionFingerprint, store: store)
        XCTAssertEqual(oldSelection?.1.artifact, registered.artifact)
        let copy = try store.createVirtualCopy(of: original, name: "外部成片")
        let editor = try EditingController(store: store, libraryURL: fixture.library, defaults: fixture.defaults)
        do {
            editor.isPresented = true
            let offlinePath = fixture.root.appendingPathComponent("unplugged.png")
            for available in [true, false, true] {
                if !available { try FileManager.default.moveItem(at: original.resolvedURL, to: offlinePath) }
                else if FileManager.default.fileExists(atPath: offlinePath.path) {
                    try FileManager.default.moveItem(at: offlinePath, to: original.resolvedURL)
                }
                try store.refreshAvailability(ids: [original.id])
                let item = copy.projecting(try store.asset(original.id))
                XCTAssertEqual(item.availability, available ? .available : .missing)
                editor.focus(item, admissionFingerprint: source.admissionFingerprint)
                try await wait { !editor.loading && editor.previews.primary.frameSourceKey?.hasPrefix("artifact:") == true }
                XCTAssertEqual(editor.sourceReady, available)
                XCTAssertEqual(editor.work?.presentationID, copy.id)
                XCTAssertEqual(editor.selectedVersion?.configuration["virtualCopyArchiveSource"], registered.id)
                let artifact = try XCTUnwrap(editor.selectedVersion?.artifact)
                XCTAssertEqual(try FileSafety.hash(archive.artifactURL(artifact)), pixels.sha256)
                XCTAssertTrue(editor.beginSavedResultExport(try XCTUnwrap(editor.selectedVersion)))
                let frozen = try await editor.workbenchExportInput(for: copy.id)
                XCTAssertEqual(frozen?.0.presentationID, copy.id)
                XCTAssertEqual(frozen?.1.artifact, artifact)
            }
            editor.focus(original, admissionFingerprint: source.admissionFingerprint)
            try await wait { !editor.loading && editor.work?.id == master.id }
            XCTAssertEqual(editor.stage, .versions)
            XCTAssertEqual(editor.selectedVersion?.id, registered.id)
            editor.returnToCurrentEdit()
            XCTAssertEqual(editor.recipe, earlier)
            editor.setRecipe { $0.exposureEV = -0.5 }
            try await editor.awaitPendingRenditionWrites(for: original.id)
            let edited = try store.photoWork(id: master.id)
            XCTAssertTrue(edited.usesLiveRendition(over: registered))
            XCTAssertEqual(edited.adoptedVersionID, registered.id)
            let current = try AppModel.storedWorkbenchInput(original, fingerprint: source.admissionFingerprint, store: store)
            XCTAssertEqual(current?.1.recipe.exposureEV, -0.5)
            XCTAssertNil(current?.1.artifact)
            let newer = try store.createVirtualCopy(of: original, name: "返回调整的新副本")
            XCTAssertEqual(try store.photoWork(id: newer.id).liveRecipe?.exposureEV, -0.5)
            let archivedCopy = try store.photoWork(id: copy.id)
            XCTAssertEqual(try store.editingVersion(id: archivedCopy.adoptedVersionID).artifact, registered.artifact)
            editor.leaveBrowsingContext()
            editor.isPresented = true
            editor.focus(original, admissionFingerprint: source.admissionFingerprint)
            try await wait { !editor.loading && editor.work?.id == master.id }
            XCTAssertEqual(editor.stage, .development)
            XCTAssertEqual(editor.recipe.exposureEV, -0.5)
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }

    @MainActor func testRealSourceAndCopyKeepIndependentDraftsSnapshotsHistoriesAndFrozenSelection() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
            throw XCTSkip("Supply the authorized 24 MP snow ARW")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let database = root.appendingPathComponent("library.sqlite")
        let original = try NativePresentedCanvasTests.register(source: URL(fileURLWithPath: path), library: database)
        let store = try LibraryStore(databaseURL: database)
        let admission = try store.captureEditingSourceSnapshot(assetID: original.id).admissionFingerprint
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        var editor = try EditingController(store: store, libraryURL: database, defaults: defaults)
        @MainActor func focus(_ item: AssetRecord) async throws {
            editor.isPresented = true
            editor.focus(item, admissionFingerprint: admission)
            try await wait { editor.sourceReady && !editor.loading && editor.work?.presentationID == item.id }
            editor.beginDevelopmentInterface()
            if editor.recipe.sceneGraph == nil {
                try await wait { editor.developmentContext?.workID == editor.work?.id }
            }
        }
        do {
            try await focus(original)
            let master = try XCTUnwrap(editor.work)
            var color = try editor.recipe.promotingToV3()
            color.adjustmentsV3?.color = .init(enabled: true, saturation: 0.33)
            editor.setRecipe { $0 = color }
            let masterContext = try XCTUnwrap(editor.developmentContext)
            let colorSnapshot = try editor.developmentSession.createSnapshot(name: "彩色原片", context: masterContext)
            editor.leaveBrowsingContext()
            try await editor.awaitPendingRenditionWrites(for: original.id)
            let copy = try store.createVirtualCopy(of: original, name: "黑白角度")
            let rendition = copy.projecting(original)
            XCTAssertEqual(rendition.physicalAssetID, original.id)
            try await focus(rendition)
            XCTAssertEqual(editor.recipe, color)
            XCTAssertTrue(editor.developmentSession.snapshots.isEmpty)
            XCTAssertThrowsError(try editor.developmentSession.deleteSnapshot(id: colorSnapshot.id, context: masterContext))
            editor.setLegacyColorMode(ticket: try XCTUnwrap(editor.sceneTicket), monochrome: true)
            try await wait { editor.developmentContext != nil }
            let monochrome = editor.recipe
            XCTAssertEqual(monochrome.adjustmentsV3?.blackAndWhite.enabled, true)
            XCTAssertNotEqual(monochrome, color)
            let copyContext = try XCTUnwrap(editor.developmentContext)
            let bwSnapshot = try editor.developmentSession.createSnapshot(name: "单色副本", context: copyContext)
            editor.enterSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket))
            try await wait { !editor.sceneStarting }
            let graph = try XCTUnwrap(editor.recipe.sceneGraph), node = try XCTUnwrap(graph.graph.nodes.first)
            let initialHDR = editor.recipe
            let oldTicket = try XCTUnwrap(editor.sceneTicket)
            editor.setSceneExposure(1.75, node: node.id, ticket: oldTicket)
            let alteredHDR = editor.recipe
            XCTAssertNotEqual(alteredHDR, initialHDR)
            editor.createSceneSnapshot(ticket: try XCTUnwrap(editor.sceneTicket))
            let hdrSnapshot = try XCTUnwrap(editor.sceneSnapshots.first)
            try await focus(original)
            editor.setSceneExposure(-2, node: node.id, ticket: oldTicket)
            XCTAssertEqual(editor.recipe, color)
            XCTAssertEqual(editor.developmentSession.snapshots.map(\.id), [colorSnapshot.id])
            XCTAssertTrue(editor.sceneSnapshots.isEmpty)
            editor.postNotice("副本后台事件", for: copy.id)
            XCTAssertFalse(editor.photoNotices.contains { $0.text == "副本后台事件" })
            XCTAssertTrue(editor.activity.notices.contains { $0.assetID == copy.id && $0.photoName == copy.name && $0.text == "副本后台事件" })
            XCTAssertTrue(editor.beginWorkbenchExport(asset: rendition, admissionFingerprint: admission))
            let frozen = try await editor.workbenchExportInput(for: copy.id)
            XCTAssertEqual(frozen?.0.id, copy.id)
            XCTAssertEqual(frozen?.1.source.assetID, original.id)
            XCTAssertEqual(frozen?.1.recipe, alteredHDR)
            XCTAssertEqual(editor.sceneSnapshots.map(\.id), [hdrSnapshot.id])
            XCTAssertTrue(editor.stepSceneHistory(redo: false))
            XCTAssertEqual(editor.recipe, initialHDR)
            XCTAssertTrue(editor.stepSceneHistory(redo: true))
            XCTAssertEqual(editor.recipe, alteredHDR)
            try await editor.awaitPendingRenditionWrites(for: copy.id)
            XCTAssertEqual(try store.photoWork(id: master.id).liveRecipe, color)
            XCTAssertEqual(try store.photoWork(id: copy.id).liveRecipe, alteredHDR)
            await editor.shutdown()
            editor = try EditingController(store: LibraryStore(databaseURL: database), libraryURL: database, defaults: defaults)
            try await focus(original)
            XCTAssertEqual(editor.recipe, color)
            XCTAssertEqual(editor.developmentSession.snapshots.map(\.id), [colorSnapshot.id])
            try await focus(rendition)
            XCTAssertEqual(editor.recipe, alteredHDR)
            XCTAssertEqual(editor.sceneSnapshots.map(\.id), [hdrSnapshot.id])
            editor.leaveSceneDraft(ticket: try XCTUnwrap(editor.sceneTicket), monochrome: true)
            try await wait { editor.developmentContext != nil }
            XCTAssertEqual(editor.recipe, monochrome)
            XCTAssertEqual(editor.developmentSession.snapshots.map(\.id), [bwSnapshot.id])
            XCTAssertEqual(try store.editingWorks(for: original).map(\.id), [master.id])
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }
}
