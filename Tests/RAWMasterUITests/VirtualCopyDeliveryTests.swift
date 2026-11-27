import AppKit
import CryptoKit
import ImageIO
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

@MainActor
final class VirtualCopyDeliveryTests: XCTestCase {
    func testSingleAndPairedDeliveriesKeepTheirOwnRecipeThroughReopenAndRemoval() async throws {
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/burst14-context38/files/asset0000.jpg")
        try await checkDeliveries(source: sample, raw: false, evidence: nil)
    }

    func testArchivedDevelopmentCopyExportsOfflineThenEditsItsOwnRecipeFromTheWorkbench() async throws {
        let fixture = try EditingWorkflowTests.Fixture(photoCount: 1)
        defer { fixture.clean() }
        let store = fixture.store, asset = fixture.assets[0]
        let source = try store.captureEditingSourceSnapshot(assetID: asset.id)
        let master = try store.createPhotoWork(source: source)
        let recipe = DevelopmentRecipe(exposureEV: 0.75)
        let archive = try EditingController.openArchive(store: store, libraryURL: fixture.library)
        let originalResult = try await DevelopmentService().render(source: source, recipe: recipe, format: .png16,
            destination: fixture.root.appending(path: "developed.png"))
        let candidate = EditingVersion(workID: master.id, parentVersionID: master.originalVersionID,
            kind: .development, source: source, recipe: recipe, artifact: originalResult.artifact)
        let registered = try store.commitArchivePublication(archive.publish(fileURL: originalResult.fileURL, version: candidate))
        _ = try store.adoptEditingVersion(workID: master.id, versionID: registered.id, expectedRevision: 0)
        let copy = try store.createVirtualCopy(of: asset, name: "曝光副本")
        let missing = fixture.root.appending(path: "detached.png")
        try FileManager.default.moveItem(at: asset.resolvedURL, to: missing)
        try store.refreshAvailability(ids: [asset.id])
        let config = PhotoBatchExportConfiguration(format: .jpeg8, jpegQuality: 0.95)
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults)
        model.selectScope(.project, id: asset.projectID)
        let editor = try XCTUnwrap(model.editing)
        do {
            try await wait { model.filteredAssets.contains { $0.id == copy.id && $0.availability == .missing } }
            model.select(copy.projecting(try store.asset(asset.id))); model.openSelectionExport()
            try await wait { model.exportWorkspacePresented && model.workbenchExportCandidates.map(\.id) == [copy.id] }
            let offlineFiles = try await model.exportWorkbenchPhotos(directory: fixture.root.appending(path: "offline"),
                namingTemplate: "{name}", configuration: config, includedIDs: [copy.id]) { _, _, _ in }
            let offline = try pixels(XCTUnwrap(offlineFiles.first))
            XCTAssertEqual(offlineFiles.map(\.lastPathComponent), ["QA-0-曝光副本.jpg"])

            model.activateWorkflow(.library)
            try FileManager.default.moveItem(at: missing, to: asset.resolvedURL)
            try store.refreshAvailability(ids: [asset.id]); model.reload()
            try await wait { model.filteredAssets.contains { $0.id == copy.id && $0.availability == .available } }
            model.select(copy.projecting(try store.asset(asset.id))); model.setMode(.single); model.openNativeEditing()
            try await wait { editor.work?.id == copy.id && editor.sourceReady && !editor.loading }
            XCTAssertEqual(editor.stage, .development)
            XCTAssertEqual(editor.recipe, recipe)
            XCTAssertEqual(editor.selectedVersion?.artifact, registered.artifact)
            editor.setRecipe { $0.exposureEV = -1.25 }
            try await editor.awaitPendingRenditionWrites(for: copy.id)
            model.openRenderedPhotoExport()
            try await wait { model.exportWorkspacePresented && editor.hasWorkbenchExport(for: copy.id) }
            let captured = try await editor.workbenchExportInput(for: copy.id)
            let frozen = try XCTUnwrap(captured?.1)
            XCTAssertNil(frozen.artifact)
            XCTAssertNil(frozen.configuration["virtualCopyArchiveSource"])
            let grid = try XCTUnwrap(AppModel.storedWorkbenchInput(copy.projecting(asset), fingerprint: source.admissionFingerprint, store: store))
            XCTAssertEqual(grid.1, frozen)
            let newFiles = try await model.exportWorkbenchPhotos(directory: fixture.root.appending(path: "adjusted"),
                namingTemplate: "{name}", configuration: config, includedIDs: [copy.id]) { _, _, _ in }
            XCTAssertNotEqual(try pixels(XCTUnwrap(newFiles.first)).digest, offline.digest)
            XCTAssertEqual(try store.photoWork(id: master.id).adoptedVersionID, registered.id)
            XCTAssertEqual(try store.editingVersion(id: registered.id).recipe, recipe)
            XCTAssertEqual(try FileSafety.hash(archive.artifactURL(XCTUnwrap(registered.artifact))), originalResult.artifact.sha256)
            let changed = try store.photoWork(id: copy.id)
            XCTAssertEqual(changed.liveRecipe?.exposureEV, -1.25)
            let readopted = try store.adoptEditingVersion(workID: copy.id, versionID: changed.adoptedVersionID,
                expectedRevision: changed.adoptionRevision)
            XCTAssertFalse(readopted.usesLiveRendition(over: try store.editingVersion(id: readopted.adoptedVersionID)))
        } catch { await editor.shutdown(); throw error }
        await editor.shutdown()
    }

    func testOptInRealARWColorAndMonochromeDelivery() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
            throw XCTSkip("Requires the fixed 24 MP snow ARW")
        }
        let evidence = ProcessInfo.processInfo.environment["RAWMASTER_VIRTUAL_COPY_DELIVERY_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        let phase = ProcessInfo.processInfo.environment["RAWMASTER_VIRTUAL_COPY_DELIVERY_PHASE"]
        if phase == "resume" {
            let root = try XCTUnwrap(evidence)
            let handoff = try JSONDecoder().decode(Handoff.self, from: Data(contentsOf: root.appending(path: "frozen.json")))
            XCTAssertNotEqual(handoff.pid, ProcessInfo.processInfo.processIdentifier)
            try await resume(handoff, root: root, evidence: evidence)
        } else {
            try await checkDeliveries(source: URL(fileURLWithPath: path), raw: true, evidence: evidence, externalRestart: phase == "freeze")
        }
    }

    func testOptInPQReviewAndPublicationSeparateTwoLooksOnOneARW() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
            throw XCTSkip("Requires the fixed 24 MP snow ARW")
        }
        let suite = "VirtualCopyPQ-" + UUID().uuidString
        let evidence = ProcessInfo.processInfo.environment["RAWMASTER_VIRTUAL_COPY_PQ_EVIDENCE"].map { URL(fileURLWithPath: $0) }
        let root = evidence ?? FileManager.default.temporaryDirectory.appending(path: suite)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if evidence == nil { try? FileManager.default.removeItem(at: root) } }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let db = root.appending(path: "library.sqlite")
        let asset = try NativePresentedCanvasTests.register(source: URL(fileURLWithPath: path), library: db)
        let store = try LibraryStore(databaseURL: db)
        let master = try store.createPhotoWork(source: store.captureEditingSourceSnapshot(assetID: asset.id))
        func scene(_ exposure: Float) throws -> DevelopmentRecipe {
            let node = DevelopmentSceneGraphV1.Node(name: "曝光", operation: .corrector(image: .input, mask: nil,
                exposureEV: exposure, curve: [], strength: 1, enabled: true))
            return try DevelopmentRecipe(sceneGraph: .init(graph: .init(nodes: [node], output: .node(node.id)),
                output: .init(sdrTrim: .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))))
        }
        _ = try store.saveLiveDevelopmentState(workID: master.id, recipe: scene(0.5),
            parentVersionID: master.originalVersionID, expectedRevision: 0)
        let copy = try store.createVirtualCopy(of: asset, name: "低曝光")
        let copyWork = try store.photoWork(id: copy.id), selection = [asset, copy.projecting(asset)]
        let updated = try store.saveLiveDevelopmentState(workID: copy.id, recipe: scene(-0.75),
            parentVersionID: copyWork.originalVersionID, expectedRevision: copyWork.liveRevision ?? 0)
        let model = AppModel(libraryURL: db, defaults: defaults)
        model.selectScope(.project, id: asset.projectID)
        let review = try await model.reviewWorkbenchPQ(selection)
        XCTAssertTrue(review.canSubmit)
        XCTAssertEqual(review.identifiers, [asset.id, copy.id])
        XCTAssertEqual(Set(review.lines.compactMap(\.sourceDigest)).count, 1)
        XCTAssertEqual(Set(review.lines.compactMap(\.recipeDigest)).count, 2)
        XCTAssertEqual(Set(review.lines.compactMap(\.version)).count, 2)
        _ = try store.saveLiveDevelopmentState(workID: copy.id, recipe: scene(-1.25),
            parentVersionID: copyWork.originalVersionID, expectedRevision: updated.liveRevision ?? 0)
        let destination = root.appending(path: "PQ")
        var values = ExportWorkspaceSettings()
        values.pqDelivery = true
        let settings = values.resolvedConfiguration
        do {
            _ = try await model.exportWorkbenchPhotos(directory: destination, namingTemplate: "{name}", configuration: settings,
                includedIDs: review.identifiers, pqReview: review) { _, _, _ in }
            XCTFail("A changed copy replaced the reviewed HDR version")
        } catch WorkbenchDeliveryIssue.pqSelectionChanged {}
        let current = try await model.reviewWorkbenchPQ(selection)
        let files = try await model.exportWorkbenchPhotos(directory: destination, namingTemplate: "{name}", configuration: settings,
            includedIDs: current.identifiers, pqReview: current) { _, _, _ in }
        XCTAssertEqual(files.count, 2)
        let digests = try Set(files.map { try FileSafety.hash($0) })
        XCTAssertEqual(digests.count, 2)
        for file in files {
            let input = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any])
            let signal = try DevelopmentSceneAVIFV1.readSignal(Data(contentsOf: file))
            XCTAssertEqual(signal.bitDepth, 10); XCTAssertEqual(signal.primaries, 9); XCTAssertEqual(signal.transfer, 16)
            XCTAssertTrue(signal.fullRange)
            XCTAssertEqual(Set([properties[kCGImagePropertyPixelWidth] as? Int, properties[kCGImagePropertyPixelHeight] as? Int]),
                           Set([asset.width, asset.height]))
        }
        await model.editing?.shutdown()
    }

    private func checkDeliveries(source: URL, raw: Bool, evidence: URL?, externalRestart: Bool = false) async throws {
        let fm = FileManager.default, suite = "VirtualCopyDelivery-" + UUID().uuidString
        let root = evidence ?? fm.temporaryDirectory.appendingPathComponent(suite)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { if evidence == nil { try? fm.removeItem(at: root) } }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { if !externalRestart { defaults.removePersistentDomain(forName: suite) } }
        let db = root.appending(path: "library.sqlite")
        let local = root.appending(path: "originals").appending(path: source.lastPathComponent)
        try fm.createDirectory(at: local.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: source, to: local)
        let asset = try NativePresentedCanvasTests.register(source: local, library: db, requiresRAW: raw)
        let store = try LibraryStore(databaseURL: db)
        let admitted = try store.captureEditingSourceSnapshot(assetID: asset.id)
        let original = try store.createPhotoWork(source: admitted, rawDecoder: raw ? .flashRaw031 : nil)
        var color = try store.editingVersion(id: original.originalVersionID).recipe.promotingToV3()
        color.adjustmentsV3?.color = .init(enabled: true, saturation: 0.35)
        _ = try store.saveLiveDevelopmentState(workID: original.id, recipe: color, parentVersionID: original.originalVersionID, expectedRevision: 0)
        let copy = try store.createVirtualCopy(of: asset, name: "黑白")
        let selection = copy.projecting(asset), copyWork = try store.photoWork(id: copy.id)
        XCTAssertEqual(copyWork.liveRecipe, color)
        var mono = color
        mono.adjustmentsV3?.blackAndWhite.enabled = true
        let edited = try store.saveLiveDevelopmentState(workID: copy.id, recipe: mono, parentVersionID: copyWork.originalVersionID,
                                                       expectedRevision: copyWork.liveRevision ?? 0)
        let config = PhotoBatchExportConfiguration(format: .jpeg8, maximumLongEdge: 512)
        let masterStem = (asset.filename as NSString).deletingPathExtension
        let copyName = masterStem + "-黑白.jpg"
        var named = selection
        named.virtualCopyName = "青/蓝:春"
        XCTAssertEqual(try PhotoExportFilename.stem(for: named, ordinal: 1, template: "{name}", exportDate: Date()), masterStem + "-青-蓝-春")
        let ids = [asset.id, selection.id]
        let start = Date()
        let singleSeconds, pairSeconds: Double
        let single: Pixels
        let batchID: String
        do {
            let model = AppModel(libraryURL: db, defaults: defaults)
            model.selectScope(.project, id: asset.projectID)
            try await wait { model.filteredAssets.contains { $0.id == copy.id } }
            model.select(selection); model.setMode(.single); model.openNativeEditing()
            let editor = try XCTUnwrap(model.editing)
            try await wait { editor.work?.id == copy.id && !editor.loading }
            model.openRenderedPhotoExport()
            try await wait { model.exportWorkspacePresented && model.workbenchExportCandidates.count == 1 }
            XCTAssertEqual(model.workbenchExportCandidates.map(\.id), [selection.id])
            let singleStart = Date()
            let files = try await model.exportWorkbenchPhotos(directory: root.appending(path: "single"), namingTemplate: "{name}",
                configuration: config, includedIDs: [selection.id]) { _, _, _ in }
            XCTAssertEqual(files.map(\.lastPathComponent), [copyName])
            singleSeconds = Date().timeIntervalSince(singleStart)
            single = try pixels(XCTUnwrap(files.first))
            XCTAssertLessThan(single.chroma, 1.5)

            model.activateWorkflow(.library); model.setMode(.grid)
            model.select(asset); model.select(selection, modifiers: .command); model.openSelectionExport()
            try await wait { model.exportWorkspacePresented && model.workbenchExportCandidates.count == 2 }
            XCTAssertEqual(Set(model.workbenchExportCandidates.map(\.id)), Set(ids))
            let reported = try XCTUnwrap(model.exportSelection(ids: ids, formats: .allOriginals, exactAssetIDs: ids))
            XCTAssertEqual(reported.assetIDs, [asset.id])
            XCTAssertEqual(model.exportSelection(ids: [copy.id], formats: .allOriginals, exactAssetIDs: [copy.id])?.assetIDs, [asset.id])
            model.export(ids: ids, destination: root.appending(path: "original").path, exactAssetIDs: ids, csvLayout: .photoRows)
            try await wait { model.exportReport != nil && !model.isBusy }
            let report = try XCTUnwrap(model.exportReport)
            XCTAssertEqual(report.copied, 1); XCTAssertEqual(report.failed, 0)
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let originalManifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: URL(fileURLWithPath: report.manifestPath)))
            XCTAssertEqual(originalManifest.items.map { $0.asset.id }, [asset.id])
            let physicalFile = try XCTUnwrap(originalManifest.items.first?.outputPath)
            XCTAssertEqual(try FileSafety.hash(URL(fileURLWithPath: physicalFile)), admitted.contentSHA256)

            let pairStart = Date()
            let pair = try await model.exportWorkbenchPhotos(directory: root.appending(path: "pair"), namingTemplate: "{name}",
                configuration: config, includedIDs: Set(ids)) { _, _, _ in }
            pairSeconds = Date().timeIntervalSince(pairStart)
            XCTAssertEqual(Set(pair.map(\.lastPathComponent)), [masterStem + ".jpg", copyName])
            let colorful = try pixels(XCTUnwrap(pair.first { $0.lastPathComponent != copyName }))
            let bw = try pixels(XCTUnwrap(pair.first { $0.lastPathComponent == copyName }))
            XCTAssertGreaterThan(colorful.chroma, 4); XCTAssertLessThan(bw.chroma, 1.5)
            XCTAssertEqual(bw, single); XCTAssertNotEqual(colorful.digest, bw.digest)

            let queue = WorkbenchDeliveryCatalog(database: db)
            let inputs = try store.withReadSnapshot {
                try [asset, selection].map { try XCTUnwrap(AppModel.storedWorkbenchInput($0, fingerprint: admitted.admissionFingerprint, store: store)) }
            }
            let output = root.appending(path: "continued")
            try fm.createDirectory(at: output, withIntermediateDirectories: true)
            batchID = UUID().uuidString.lowercased()
            let access = WorkbenchDeliveryAccess(output)
            try access.remember(grantID: batchID, database: db, in: defaults)
            let (_, lease) = try await queue.register(batchID: batchID, libraryID: try store.catalogLibraryIdentity(),
                destination: .init(grantID: batchID, pathHint: output.path),
                context: .init(submittedAt: Date(), filenames: [asset, selection].map(\.exportPresentationName)),
                naming: "{name}", collision: "rename", stems: [masterStem, masterStem + "-黑白"], configuration: config, frozen: inputs)
            try await queue.stop(batchID: batchID, generation: lease.generation, token: lease.token, cancel: false)
            await editor.shutdown()
        }
        _ = try store.saveLiveDevelopmentState(workID: copy.id, recipe: color, parentVersionID: copyWork.originalVersionID,
                                               expectedRevision: edited.liveRevision ?? 0)
        let renamed = try store.updateVirtualCopy(copy, name: "已重命名")
        _ = try store.updateVirtualCopy(renamed, removed: true)

        let relocated = root.appending(path: "reconnected").appending(path: local.lastPathComponent)
        try fm.createDirectory(at: relocated.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: local, to: relocated)
        let handoff = Handoff(batchID: batchID, suite: suite, source: source, relocated: relocated, sha256: admitted.contentSHA256,
            ids: ids, works: [original.id, copy.id], versions: [original.originalVersionID, copyWork.originalVersionID],
            filename: asset.filename, copyName: copyName, single: single, start: start, pid: ProcessInfo.processInfo.processIdentifier,
            singleSeconds: singleSeconds, pairSeconds: pairSeconds)
        if externalRestart {
            let output = try XCTUnwrap(evidence)
            XCTAssertTrue(defaults.synchronize())
            try JSONEncoder().encode(handoff).write(to: output.appending(path: "frozen.json"), options: .atomic)
        } else {
            try await resume(handoff, root: root, evidence: evidence)
        }
    }

    private struct Handoff: Codable {
        let batchID, suite: String
        let source: URL
        let relocated: URL?
        let sha256: String
        let ids, works, versions: [String]
        let filename, copyName: String
        let single: Pixels
        let start: Date
        let pid: Int32
        let singleSeconds, pairSeconds: Double?
    }

    private func resume(_ handoff: Handoff, root: URL, evidence: URL?) async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: handoff.suite))
        defer { defaults.removePersistentDomain(forName: handoff.suite) }
        let reopened = AppModel(libraryURL: root.appending(path: "library.sqlite"), defaults: defaults)
        if let relocated = handoff.relocated {
            let details = try await reopened.workbenchDeliveryDetails(handoff.batchID)
            try await reopened.reconnectWorkbenchSource(details, ordinal: 2, granted: relocated)
        }
        let resumeStart = Date()
        try await reopened.resumeWorkbenchPhotoDelivery(handoff.batchID)
        let task = try XCTUnwrap(reopened.workbenchPhotoDeliveryTask)
        await task.value
        let resumeSeconds = Date().timeIntervalSince(resumeStart)
        let status = try await reopened.workbenchDeliveryDetails(handoff.batchID)
        let manifest = try XCTUnwrap(status.receipt.manifest)
        XCTAssertEqual(status.receipt.batch.phase, .done, reopened.workbenchPhotoDelivery?.message ?? "")
        XCTAssertEqual(manifest.items.map(\.selectionID), handoff.ids)
        XCTAssertEqual(manifest.items.map(\.assetID), [handoff.ids[0], handoff.ids[0]])
        XCTAssertEqual(manifest.items.map(\.workID), handoff.works)
        XCTAssertEqual(manifest.items.map(\.versionID), handoff.versions)
        XCTAssertEqual(manifest.sourceContext.filenames, [handoff.filename, handoff.filename + " · 黑白"])
        let continued = try pixels(root.appending(path: "continued").appending(path: handoff.copyName))
        XCTAssertEqual(continued, handoff.single)
        XCTAssertEqual(try FileSafety.hash(handoff.source), handoff.sha256)
        if let evidence {
            let rows = try (reopened.workbenchPhotoDelivery?.files ?? []).map { file in
                let image = try pixels(file)
                return ["name":file.lastPathComponent, "width":image.width, "height":image.height,
                        "fileSHA256":try FileSafety.hash(file), "sRGB64pxSHA256":image.digest, "meanChroma8":image.chroma] as [String: Any]
            }
            let receipt: [String: Any] = ["physicalSource":handoff.filename, "physicalSHA256":handoff.sha256,
                "presentationIDs":handoff.ids, "workIDs":manifest.items.map(\.workID), "versionIDs":manifest.items.map(\.versionID),
                "batchID":handoff.batchID, "generation":status.receipt.batch.generation, "originalCopies":1,
                "elapsedIncludingRestart":Date().timeIntervalSince(handoff.start), "files":rows,
                "renderSeconds":["single":handoff.singleSeconds ?? 0, "pair":handoff.pairSeconds ?? 0, "resumePair":resumeSeconds],
                "freezingProcess":handoff.pid, "resumingProcess":ProcessInfo.processInfo.processIdentifier,
                "oneSourceRelinkForBoth":handoff.relocated != nil]
            try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys, .prettyPrinted])
                .write(to: evidence.appending(path: "delivery.json"), options: .atomic)
        }
        await reopened.editing?.shutdown()
    }

    private struct Pixels: Codable, Equatable { let width, height: Int; let digest: String; let chroma: Double }

    private func pixels(_ file: URL) throws -> Pixels {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let size = 64, stride = size * 4
        var bytes = [UInt8](repeating: 0, count: stride * size)
        try bytes.withUnsafeMutableBytes { storage in
            let context = try XCTUnwrap(CGContext(data: storage.baseAddress, width: size, height: size,
                bitsPerComponent: 8, bytesPerRow: stride, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        }
        var sum = 0
        for offset in Swift.stride(from: 0, to: bytes.count, by: 4) {
            let r = bytes[offset], g = bytes[offset + 1], b = bytes[offset + 2]
            sum += Int(max(r, max(g,b)) - min(r, min(g,b)))
        }
        return Pixels(width: image.width, height: image.height,
            digest: SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined(),
            chroma: Double(sum) / Double(size * size))
    }

    private func wait(_ ready: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !ready() && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try Task.checkCancellation()
        _ = try XCTUnwrap(ready() ? true : nil, "Timed out waiting for the workbench", file: file, line: line)
    }
}
