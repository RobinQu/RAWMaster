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

extension WorkbenchContinuation035Tests {
    func testWorkbenchPQSettingsLeavePortableSDRPresetsUnchanged() throws {
        var values = ExportWorkspaceSettings()
        values.sizeChoice = 2048
        values.configuration.layout = .init(style: .paper)
        let before = try values.portable(named: "Safe SDR").fileData()
        values.pqDelivery = true
        let config = values.resolvedConfiguration
        XCTAssertEqual(config.format, .avif10)
        XCTAssertNil(config.maximumLongEdge)
        XCTAssertEqual(config.metadataPolicy, .none)
        try config.validate()
        XCTAssertEqual(try values.portable(named: "Safe SDR").fileData(), before)
        var invalid = config; invalid.maximumLongEdge = 2048
        XCTAssertThrowsError(try invalid.validate())
        invalid = config; invalid.layout = .init(style: .paper)
        XCTAssertThrowsError(try invalid.validate())
        invalid = config; invalid.metadataPolicy = .rights
        XCTAssertThrowsError(try invalid.validate())
        values.pqDelivery = false
        XCTAssertEqual(values.resolvedConfiguration.maximumLongEdge, 2048)
        XCTAssertEqual(values.resolvedConfiguration.layout.style, .paper)
    }

    @MainActor func testOptInWorkbenchPQPreparedAcrossProcesses() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_037_PQ_RESTART_ROOT"], let phase = env["RAWMASTER_037_PQ_RESTART_PHASE"],
              let fixtures = env["RAWMASTER_SCENE_RAW_FIXTURES"] else { throw XCTSkip("Use isolated 037 process-restart runner and fixed person/snow RAWs") }
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        let db = root.appending(path: "catalog/library.sqlite"), input = root.appending(path: "originals"), output = root.appending(path: "delivery")
        let store = try LibraryStore(databaseURL: db), queue = WorkbenchDeliveryCatalog(database: db)
        let suite = "rawmaster-pq-restart-" + root.lastPathComponent
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        if phase == "write" {
            let fixed = URL(fileURLWithPath: fixtures, isDirectory: true)
            try FileManager.default.createDirectory(at: input, withIntermediateDirectories: false)
            let expected = ["person.ARW": "0a0775e6f803329341b954fd4d0ed08d6cc71b3b226c34d0218865761e31f0d8", "snow.ARW": "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2"]
            for (name, digest) in expected {
                let url = fixed.appending(path: name)
                XCTAssertEqual(try FileSafety.hash(url), digest)
                try FileManager.default.copyItem(at: url, to: input.appending(path: name))
            }
            let jpeg = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: "RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/dji187-context376/files/asset0000.jpg")
            try FileManager.default.copyItem(at: jpeg, to: input.appending(path: "sdr.jpg"))
            _ = try await ImportService(store: store).importDirectory(source: input, destination: nil,
                projectName: "037 PQ restart", mode: .reference, progress: { _ in })
            let assets = try store.loadAssets()
            XCTAssertEqual(assets.count, 3)
            for asset in assets where expected[asset.filename] != nil {
                let source = try store.captureEditingSourceSnapshot(assetID: asset.id)
                let work = try store.createPhotoWork(source: source)
                let grade = DevelopmentSceneGraphV1.Node(id: UUID(uuidString: "37800000-0000-4000-8000-000000000001")!,
                    name: "Scene", operation: .corrector(image: .input, mask: nil, exposureEV: 1, curve: [], strength: 1, enabled: true))
                let graph = try DevelopmentSceneGraphV1(graph: .init(nodes: [grade], output: .node(grade.id)),
                    output: .init(sdrTrim: .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0)))
                let version = try store.appendEditingVersion(.init(workID: work.id, parentVersionID: work.originalVersionID,
                    kind: .development, source: source, recipe: .init(sceneGraph: graph)))
                _ = try store.adoptEditingVersion(workID: work.id, versionID: version.id, expectedRevision: 0)
            }
            let model = AppModel(libraryURL: db, defaults: defaults, editingPreviewBackend: PhotosDevelopmentBackend())
            let candidates = model.workbenchExportCandidates
            XCTAssertEqual(candidates.count, 3)
            let config = PhotoBatchExportConfiguration(format: .avif10, jpegQuality: 0.95)
            let mixed = try await model.reviewWorkbenchPQ(candidates)
            XCTAssertFalse(mixed.canSubmit)
            XCTAssertTrue(mixed.lines.contains { $0.name == "sdr.jpg" && $0.reason?.contains("没有 HDR 母版") == true })
            do {
                _ = try await model.exportWorkbenchPhotos(directory: output, namingTemplate: "{name}-{index}", configuration: config,
                    includedIDs: Set(candidates.map(\.id)), pqReview: mixed) { _, _, _ in }
                XCTFail("an explicit HDR batch cannot fall back to SDR")
            } catch WorkbenchDeliveryIssue.pqSelectionChanged {}
            let noJobs = try await queue.history()
            XCTAssertTrue(noJobs.isEmpty)
            let ready = candidates.filter { expected[$0.filename] != nil }
            let review = try await model.reviewWorkbenchPQ(ready)
            XCTAssertTrue(review.canSubmit, "\(review.lines.compactMap(\.reason))")
            let reviewedAsset = try XCTUnwrap(ready.first)
            let reviewedWork = try XCTUnwrap(store.loadPhotoWorks(assetID: reviewedAsset.id).first)
            let pinned = try store.editingVersion(id: reviewedWork.adoptedVersionID)
            let replacement = try store.appendEditingVersion(.init(workID: reviewedWork.id, parentVersionID: pinned.id,
                kind: .development, source: reviewedWork.source, recipe: pinned.recipe))
            _ = try store.adoptEditingVersion(workID: reviewedWork.id, versionID: replacement.id, expectedRevision: reviewedWork.adoptionRevision)
            do {
                _ = try await model.exportWorkbenchPhotos(directory: output, namingTemplate: "{name}-{index}", configuration: config,
                    includedIDs: review.identifiers, pqReview: review) { _, _, _ in }
                XCTFail("the reviewed version cannot be substituted even with the same recipe")
            } catch WorkbenchDeliveryIssue.pqSelectionChanged {}
            _ = try store.adoptEditingVersion(workID: reviewedWork.id, versionID: pinned.id, expectedRevision: reviewedWork.adoptionRevision + 1)
            let staleJobs = try await queue.history(); XCTAssertTrue(staleJobs.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
            model.workbenchExportContext = .selection(ids: Array(review.identifiers))
            model.activateWorkflow(.export)
            model.workbenchDeliveryCheckpoint = { ordinal, checkpoint in
                guard ordinal == 2, checkpoint == .prepared else { return }
                _ = UserDefaults(suiteName: suite)?.synchronize()
                do { try Data("\(getpid()) prepared".utf8).write(to: root.appending(path: "checkpoint"), options: .atomic) }
                catch { fatalError("Unable to record isolated fixture checkpoint: \(error)") }
                kill(getpid(), SIGSTOP)
            }
            model.submitWorkbenchPhotoDelivery(directory: output, naming: "{name}.pq-{index}", configuration: config,
                ids: review.identifiers, collision: "rename", pqReview: review)
            await model.workbenchPhotoDeliveryTask?.value
            XCTFail("Did not reach prepared checkpoint: \(model.workbenchPhotoDelivery?.message ?? "no job")")
            return
        }

        XCTAssertEqual(phase, "reopen")
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = try await queue.history()
        let batchID = try XCTUnwrap(history.first?.id)
        XCTAssertEqual(history.count, 1)
        let before = try await settlePriorWriter(queue, batchID: batchID)
        XCTAssertEqual(before.batch.phase, .interrupted)
        XCTAssertEqual(before.manifest?.schema, 2)
        let config = try await queue.configuration(batchID: batchID)
        XCTAssertEqual(config.format, .avif10)
        let first = try XCTUnwrap(before.items.items.first(where: { $0.ordinal == 1 })), second = try XCTUnwrap(before.items.items.first(where: { $0.ordinal == 2 }))
        XCTAssertEqual(first.state, .delivered); XCTAssertEqual(second.state, .prepared)
        let firstURL = output.appending(path: try XCTUnwrap(first.filename)), readyURL = output.appending(path: try XCTUnwrap(second.filename))
        XCTAssertFalse(FileManager.default.fileExists(atPath: readyURL.path))
        let firstIdentity = try FileSafety.stat(firstURL)
        let model = AppModel(libraryURL: db, defaults: defaults, editingPreviewBackend: PhotosDevelopmentBackend())
        let sdr = try XCTUnwrap(model.workbenchExportCandidates.first(where: { $0.filename == "sdr.jpg" }))
        model.selectedIDs = [sdr.id]
        let displaced = root.appending(path: "displaced")
        try FileManager.default.moveItem(at: output, to: displaced)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let invalid = try await model.workbenchDeliveryDetails(batchID)
        do {
            try await model.reconnectWorkbenchDestination(invalid, granted: output)
            XCTFail("another directory must not inherit a frozen PQ ticket")
        } catch WorkbenchDeliveryIssue.targetOffline {}
        try FileManager.default.removeItem(at: output)
        try FileManager.default.moveItem(at: displaced, to: output)
        try await model.reconnectWorkbenchDestination(invalid, granted: output)
        let manifest = try XCTUnwrap(before.manifest)
        let frozenSource = input.appending(path: manifest.sourceContext.filenames[1])
        let relocated = root.appending(path: "reconnected-original")
        try FileManager.default.moveItem(at: frozenSource, to: relocated)
        try await model.resumeWorkbenchPhotoDelivery(batchID)
        await model.workbenchPhotoDeliveryTask?.value
        let missing = try await model.workbenchDeliveryDetails(batchID)
        XCTAssertEqual(missing.receipt.batch.phase, .interrupted)
        XCTAssertEqual(missing.items.first(where: { $0.ordinal == 2 })?.reason, WorkbenchDeliveryIssue.sourceOffline.rawValue)
        do {
            try await model.reconnectWorkbenchSource(missing, ordinal: 2, granted: sdr.resolvedURL)
            XCTFail("cannot use different bytes for a prepared scene")
        } catch WorkbenchDeliveryIssue.sourceOffline {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: readyURL.path))
        try await model.reconnectWorkbenchSource(missing, ordinal: 2, granted: relocated)
        try await model.resumeWorkbenchPhotoDelivery(batchID)
        await model.workbenchPhotoDeliveryTask?.value
        let final = try await queue.receipt(batchID: batchID)
        XCTAssertEqual(final.batch.phase, .done, model.workbenchPhotoDelivery?.message ?? "")
        XCTAssertEqual(final.manifest?.items.map(\.versionID), before.manifest?.items.map(\.versionID))
        XCTAssertEqual(try FileSafety.stat(firstURL), firstIdentity)
        XCTAssertEqual(try FileSafety.hash(firstURL), first.sha256)
        XCTAssertEqual(try FileSafety.hash(readyURL), second.sha256)
        XCTAssertEqual(model.selectedIDs, [sdr.id])
        let files = [firstURL, readyURL]
        XCTAssertTrue(files.allSatisfy { $0.pathExtension == "avif" })
        let body: [String: Any] = ["status": "passed", "manifestSchema": 2, "target": config.format.rawValue,
            "files": try Dictionary(uniqueKeysWithValues: files.map { ($0.lastPathComponent, try FileSafety.hash($0)) }),
            "firstInodePreserved": true, "preparedDigestPreserved": true, "rejectedReplacementDirectory": true,
            "versionIDs": final.manifest?.items.map(\.versionID) ?? [], "selectionPreserved": true,
            "originalWasOffline": true, "rejectedDifferentSource": true, "reconnectedOriginalWithoutChangingPreparedSHA": true,
            "mixedSelectionRejectedBeforeRegistration": true, "changedVersionRejectedBeforeRegistration": true]
        try JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appending(path: "receipt.json"), options: .atomic)
        await model.editing?.shutdown()
    }
}
