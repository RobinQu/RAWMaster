import AppKit
import CryptoKit
import Darwin
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
import RAWMasterImaging

final class WorkbenchContinuation035Tests: XCTestCase {
    @MainActor func testOptInWorkbenchDeliveryAcrossProcesses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["RAWMASTER_035_RESTART_ROOT"], let phase = env["RAWMASTER_035_RESTART_PHASE"] else {
            throw XCTSkip("Use independent processes and a private 035 restart fixture directory")
        }
        let root = URL(fileURLWithPath: folder, isDirectory: true).resolvingSymlinksInPath()
        let db = env["RAWMASTER_035_RESTART_CATALOG"].map { URL(fileURLWithPath: $0) }
            ?? root.appending(path: "catalog/library.sqlite")
        let source = root.appending(path: "originals")
        let destination = env["RAWMASTER_035_RESTART_DESTINATION"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? root.appending(path: "delivery")
        let namespace = SHA256.hash(data: Data(root.path.utf8)).description.split(separator: " ").last ?? "invalid"
        let suite = "RAWMaster035-Recovery-" + namespace
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = try LibraryStore(databaseURL: db)
        if phase == "upgrade" {
            let backup = try XCTUnwrap(store.lastMigrationBackupURL)
            let version = try XCTUnwrap(store.rows("PRAGMA user_version").first?.first)
            let receipt = ["version": version, "backup": backup.path]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: root.appending(path: "upgrade-receipt.json"), options: .atomic)
            return
        }
        _ = NSApplication.shared
        if phase == "write" {
            let checkpoint = try XCTUnwrap(env["RAWMASTER_035_RESTART_CHECKPOINT"].flatMap(WorkbenchDeliveryCheckpoint.init(rawValue:)))
            try await populate(store, source: source)
            if env["RAWMASTER_035_RESTART_ADVANCED"] == "1" {
                let asset = try XCTUnwrap(store.loadAssets().first { $0.filename == "station.v2-1.jpg" })
                let snapshot = try store.captureEditingSourceSnapshot(assetID: asset.id)
                let work = try store.createPhotoWork(source: snapshot)
                var recipe = DevelopmentRecipe()
                recipe.exposureEV = 0.125
                _ = try store.saveLiveDevelopmentState(workID: work.id, recipe: recipe,
                    parentVersionID: work.originalVersionID, expectedRevision: 0)
            }
            let model = AppModel(libraryURL: db, defaults: defaults, editingPreviewBackend: PhotosDevelopmentBackend())
            let selection = model.workbenchExportCandidates.filter { $0.filename.hasPrefix("station.") }
            XCTAssertEqual(selection.count, 3)
            model.workbenchExportContext = .selection(ids: selection.map(\.id))
            model.activateWorkflow(.export)
            model.workbenchDeliveryCheckpoint = { ordinal, point in
                guard ordinal == 2, point == checkpoint else { return }
                _ = UserDefaults(suiteName: suite)?.synchronize()
                let signal = root.appending(path: "checkpoint")
                let token = "\(getpid()) \(point.rawValue)"
                do { try Data(token.utf8).write(to: signal, options: .atomic) }
                catch { fatalError("Failed to record test checkpoint: \(error)") }
                kill(getpid(), SIGSTOP)
            }
            model.submitWorkbenchPhotoDelivery(directory: destination, naming: "{name}.edit-{index}",
                configuration: .init(format: .jpeg8), ids: Set(selection.map(\.id)), collision: "rename")
            let task = try XCTUnwrap(model.workbenchPhotoDeliveryTask)
            await task.value
            XCTFail("Fixture did not stop at its native failure boundary: \(model.workbenchPhotoDelivery?.message ?? "-")")
            return
        }

        XCTAssertEqual(phase, "reopen")
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(libraryURL: db, defaults: defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let queue = WorkbenchDeliveryCatalog(database: db)
        let history = try await queue.history()
        let batchID = try XCTUnwrap(history.first?.id)
        XCTAssertEqual(history.count, 1)
        var batch = try await settlePriorWriter(queue, batchID: batchID)
        XCTAssertEqual(batch.batch.phase, .interrupted)
        let manifest = try XCTUnwrap(batch.manifest)
        XCTAssertEqual(manifest.schema, env["RAWMASTER_035_RESTART_ADVANCED"] == "1" ? 2 : 1)
        XCTAssertEqual(manifest.items.count, 3)
        XCTAssertTrue(manifest.items.allSatisfy { $0.stem.contains(".edit-") })
        let first = destination.appending(path: manifest.items[0].stem + ".jpg")
        let firstIdentity = try FileSafety.stat(first)
        let firstSHA = try FileSafety.hash(first)
        let name2 = manifest.items[1].stem + ".jpg"
        let name3 = manifest.sourceContext.filenames[2]
        let original3 = source.appending(path: name3)
        let lastSHA = try FileSafety.hash(original3)
        let modelSelection = try XCTUnwrap(model.workbenchExportCandidates.first { $0.filename == "today.jpg" })
        model.activateWorkflow(.library)
        model.selectedIDs = [modelSelection.id]
        let checkpoint = try String(contentsOf: root.appending(path: "checkpoint"), encoding: .utf8)
        let final2 = destination.appending(path: name2)
        let published = checkpoint.hasSuffix("published")
        let actualSecond = published ? try FileSafety.stat(final2) : nil
        let fm = FileManager.default

        let moved = destination.deletingLastPathComponent().appending(path: "original-delivery")
        try fm.moveItem(at: destination, to: moved)
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let detailsWhileMoved = try await model.workbenchDeliveryDetails(batchID)
        do {
            try await model.reconnectWorkbenchDestination(detailsWhileMoved, granted: destination)
            XCTFail("Reauthorized a different directory at the original path")
        } catch WorkbenchDeliveryIssue.targetOffline {}
        try fm.removeItem(at: destination)
        try fm.moveItem(at: moved, to: destination)
        try await model.reconnectWorkbenchDestination(detailsWhileMoved, granted: destination)
        let audited = try await model.workbenchDeliveryDetails(batchID)
        XCTAssertEqual(audited.items.filter(\.finished).count, published ? 2 : 1)
        XCTAssertEqual(model.selectedIDs, [modelSelection.id])

        var faultedSource = false
        if published {
            let relocated = root.appending(path: "relocated.original-bytes")
            try fm.moveItem(at: original3, to: relocated)
            try await model.resumeWorkbenchPhotoDelivery(batchID)
            let work = try XCTUnwrap(model.workbenchPhotoDeliveryTask)
            await work.value
            let offline = try await model.workbenchDeliveryDetails(batchID)
            let third = try XCTUnwrap(offline.items.first { $0.ordinal == 3 })
            XCTAssertEqual(third.reason, "sourceOffline")
            faultedSource = true
            do {
                try await model.reconnectWorkbenchSource(offline, ordinal: 3, granted: modelSelection.resolvedURL)
                XCTFail("Reauthorized different bytes for a frozen original")
            } catch WorkbenchDeliveryIssue.sourceOffline {}
            try await model.reconnectWorkbenchSource(offline, ordinal: 3, granted: relocated)
            XCTAssertEqual(try FileSafety.hash(relocated), lastSHA)
        }
        try await model.resumeWorkbenchPhotoDelivery(batchID)
        let resumed = try XCTUnwrap(model.workbenchPhotoDeliveryTask)
        await resumed.value
        batch = try await queue.receipt(batchID: batchID)
        XCTAssertEqual(batch.batch.phase, .done, model.workbenchPhotoDelivery?.message ?? "-")
        XCTAssertEqual(batch.manifest?.items.map(\.versionID), manifest.items.map(\.versionID))
        XCTAssertEqual(batch.manifest?.items.map(\.ordinal), [1, 2, 3])
        XCTAssertEqual(model.selectedIDs, [modelSelection.id])
        XCTAssertEqual(try FileSafety.stat(first), firstIdentity)
        XCTAssertEqual(try FileSafety.hash(first), firstSHA)
        if let actualSecond { XCTAssertEqual(try FileSafety.stat(final2), actualSecond) }
        let files = try fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), Set(manifest.items.map { $0.stem + ".jpg" }))
        var digests: [String: String] = [:]
        for file in files {
            let receipt = try XCTUnwrap(batch.items.items.first { $0.filename == file.lastPathComponent })
            XCTAssertEqual(receipt.state, .delivered)
            let sha = try FileSafety.hash(file)
            XCTAssertEqual(receipt.sha256, sha)
            digests[file.lastPathComponent] = sha
        }
        if published {
            let backup = root.appending(path: "editing-backup")
            let backupManifest = try store.backupEditingLibrary(to: backup)
            XCTAssertEqual(backupManifest.formatVersion, 2)
            XCTAssertEqual(backupManifest.recipeResources?.isEmpty ?? true, manifest.schema == 1)
            let restoredDB = root.appending(path: "restored/library.sqlite")
            let restored = try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: restoredDB,
                archiveRoot: root.appending(path: "restored/archive"))
            let copy = try await WorkbenchDeliveryCatalog(database: restored.databaseURL).receipt(batchID: batchID)
            XCTAssertEqual(copy.batch.phase, .historical)
            XCTAssertNil(copy.manifest)
            XCTAssertThrowsError(try WorkbenchDeliveryAccess.open(grantID: manifest.destination.grantID, database: restoredDB, in: defaults))
        }
        let evidence: [String: Any] = ["batchID": batchID, "generation": batch.batch.generation, "initialCheckpoint": checkpoint,
            "outputs": digests, "selectionPreserved": true, "firstInodePreserved": true, "postPublicationInodePreserved": published,
            "rejectedReplacementDirectory": true, "relocationCheckedAgainstSource": faultedSource, "manifestSchema": manifest.schema,
            "restoredBackupRemainedHistorical": published,
            "versionIDs": manifest.items.map(\.versionID), "status": "passed"]
        try JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys, .prettyPrinted])
            .write(to: root.appending(path: "receipt.json"), options: .atomic)
        await model.editing?.shutdown()
    }

    private func populate(_ store: LibraryStore, source: URL) async throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: false)
        for n in 0...3 {
            let original = directory.appending(path: String(format: "asset%04d.jpg", n))
            let filename = n == 3 ? "today.jpg" : "station.v2-\(n).jpg"
            try FileManager.default.copyItem(at: original, to: source.appending(path: filename))
        }
        let imported = try await ImportService(store: store).importDirectory(source: source, destination: nil,
            projectName: "035 restart fixture", mode: .reference, progress: { _ in })
        XCTAssertEqual(imported.completed, 4)
    }

    private func settlePriorWriter(_ queue: WorkbenchDeliveryCatalog, batchID: String) async throws -> WorkbenchDeliveryCatalog.Receipt {
        let deadline = ContinuousClock.now + .seconds(25)
        var batch = try await queue.receipt(batchID: batchID)
        while batch.batch.phase == .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            batch = try await queue.receipt(batchID: batchID)
        }
        return batch
    }
}
