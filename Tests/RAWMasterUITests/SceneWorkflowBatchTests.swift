import Foundation
import ImageIO
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

final class SceneWorkflowBatchTests: XCTestCase {
    func testTemplateKeepsDestinationOutputAndRemapsNestedIDs() throws {
        let node = DevelopmentSceneGraphV1.Node(name: "A", operation: .corrector(image: .input, mask: nil, exposureEV: 2,
            curve: [], strength: 1, enabled: true))
        let scope = DevelopmentSceneGraphV1.Scope(nodes: [node], output: .node(node.id))
        let trim = try DevelopmentSceneOutputStateV1.SDRTrim(exposureEV: 1, mapping: .balanced, highlightCompression: 0)
        let base = try DevelopmentSceneGraphV1(graph: scope, output: .init(sdrTrim: trim))
        let whole = try SceneWorkflowTemplate(name: " Entire ", kind: .whole, scope: scope)
        XCTAssertEqual(whole.name, "Entire")
        let replaced = try whole.applying(to: base)
        XCTAssertEqual(replaced.output.sdrTrim, trim)
        XCTAssertNotEqual(replaced.graph.nodes.first?.id, node.id)
        let group = try SceneWorkflowTemplate(name: "Group", kind: .group, scope: scope)
        let applied = try group.applying(to: base, edge: .init(.final, upstream: .node(node.id)))
        XCTAssertEqual(applied.graph.nodes.first, node)
        guard case let .group(input, child, _, _)? = applied.graph.nodes.last?.operation else { return XCTFail("Missing inserted group") }
        XCTAssertEqual(input, .node(node.id)); XCTAssertNotEqual(child.nodes.first?.id, node.id)
        let synced = try SceneWorkflowBatch.Work.exposure(-1).result(on: applied)
        XCTAssertEqual(synced.output, applied.output)
        XCTAssertEqual(synced.graph.nodes.last, applied.graph.nodes.last)
        XCTAssertEqual(synced.graph.imageEdges, applied.graph.imageEdges)
    }

    @MainActor func testOptInBatchCandidateHandsItsVersionTo032WithoutAdoption() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Use authorized snow.ARW") }
        let fixed = URL(fileURLWithPath: path), raw = fixed.deletingLastPathComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BatchHandoff-\(UUID().uuidString)")
        let photographs = root.appending(path: "photos")
        try FileManager.default.createDirectory(at: photographs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for name in ["person.ARW", "snow.ARW"] { try FileManager.default.copyItem(at: raw.appending(path: name), to: photographs.appending(path: name)) }
        let db = root.appending(path: "catalog.sqlite"), store = try LibraryStore(databaseURL: db)
        _ = try await ImportService(store: store).importDirectory(source: photographs, destination: nil, projectName: "Batch handoff", mode: .reference) { _ in }
        let assets = try store.loadAssets(), donor = try XCTUnwrap(assets.first(where: { $0.filename == "person.ARW" }))
        let target = try XCTUnwrap(assets.first(where: { $0.filename == "snow.ARW" }))
        let plan = try store.reviewSceneWorkflow(donorID: donor.id, targets: [target.id], work: .exposure(1.5), basis: .original)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: root.lastPathComponent))
        defer { defaults.removePersistentDomain(forName: root.lastPathComponent) }
        let model = AppModel(libraryURL: db, defaults: defaults)
        let selection = Set(assets.map(\.id)); model.selectedIDs = selection
        model.sceneWorkflowBatches.start(plan, in: store)
        let deadline = ContinuousClock.now + .seconds(15)
        while model.sceneWorkflowBatches.running && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.sceneWorkflowBatches.problem)
        let candidate = try XCTUnwrap(model.sceneWorkflowBatches.result?.items.first?.candidate)
        let version = try store.editingVersion(id: candidate)
        XCTAssertNotEqual(try store.photoWork(id: version.workID).adoptedVersionID, candidate)
        XCTAssertEqual(model.selectedIDs, selection)
        model.prepareLibraryExport(.workflowBatch(versions: [target.id: candidate]))
        XCTAssertEqual(model.workbenchExportCandidates.map(\.id), [target.id])
        let thumbnail = try await model.workbenchExportPreview(for: target, maxPixel: 192)
        XCTAssertEqual(thumbnail.image.height, 192)
        let out = root.appending(path: "out")
        model.submitWorkbenchPhotoDelivery(directory: out, naming: "{name}-{index}", configuration: .init(maximumLongEdge: 192), ids: [target.id], collision: "rename")
        let delivery = try XCTUnwrap(model.workbenchPhotoDelivery)
        await model.workbenchPhotoDeliveryTask?.value
        let file = try XCTUnwrap(model.workbenchPhotoDelivery?.files.first, model.workbenchPhotoDelivery?.message ?? "missing export")
        let pixels = try XCTUnwrap(CGImageSourceCreateWithURL(file as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(pixels), 1)
        let frozen = try await WorkbenchDeliveryCatalog(database: db).input(batchID: delivery.id.uuidString.lowercased(), ordinal: 1)
        XCTAssertEqual(frozen.version.id, candidate)
        XCTAssertEqual(frozen.version.recipe, version.recipe)
        XCTAssertEqual(model.selectedIDs, selection)
        await model.editing?.shutdown()
    }

    func testOptInTwentyAndTwoHundredRealRAWBatchReopenCancelRetryAndUndo() throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else { throw XCTSkip("Use authorized snow.ARW") }
        let fixture = URL(fileURLWithPath: path)
        let digest = try FileSafety.hash(fixture), bytes = try FileSafety.stat(fixture).size
        XCTAssertEqual(digest, "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneBatch-\(UUID().uuidString)")
        let originals = root.appending(path: "originals")
        try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = root.appending(path: "fixed.ARW")
        try FileManager.default.copyItem(at: fixture, to: seed)
        let db = root.appending(path: "fixture.sqlite")
        var store = try LibraryStore(databaseURL: db)
        func photo(_ index: Int) throws -> AssetRecord {
            let local = originals.appending(path: "raw-\(index).ARW")
            // Separate projects and admitted asset identities; authorized identical bytes exercise rehash and calibration reuse.
            try FileManager.default.linkItem(at: seed, to: local)
            let project = ProjectRecord(name: "Scene \(index)")
            try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: originals.path,
                mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
            try store.saveSession(session)
            let asset = try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                sourcePath: local.path, currentPath: local.path, filename: local.lastPathComponent, fileSize: bytes,
                width: 4000, height: 6000, contentHash: digest, importState: .ready))
            try store.completedDirectImport(session)
            return asset
        }
        let files = try (0...200).map(photo), donor = try XCTUnwrap(files.first)
        XCTAssertEqual(Set(files.map(\.id)).count, 201)
        let donorSnapshot = try store.captureEditingSourceSnapshot(assetID: donor.id)
        let donorWork = try store.createPhotoWork(source: donorSnapshot)
        let templateGraph = try SceneWorkflowBatch.Work.exposure(0.75).result(on: nil)
        let template = try SceneWorkflowTemplate(name: "Scene 0.75 EV", kind: .whole, scope: templateGraph.graph)
        try store.storeSceneWorkflowTemplate(template)
        var qualified: Set<String> = []
        func qualification(_ source: EditingSourceSnapshot) throws {
            if !qualified.contains(source.contentSHA256) {
                try SceneWorkflowRawQualification.verify(source)
                qualified.insert(source.contentSHA256)
            }
        }
        let small = try store.reviewSceneWorkflow(donorID: donor.id, targets: Array(files.dropFirst().prefix(20)).map(\.id),
            work: .apply(template), basis: .original)
        XCTAssertNil(try store.latestSceneWorkflow())
        let firstID = try XCTUnwrap(small.items.first?.id)
        XCTAssertTrue(try store.loadPhotoWorks(assetID: firstID).isEmpty, "review never writes a target")
        try store.registerSceneWorkflow(small)
        let start20 = ContinuousClock.now
        for row in small.items { XCTAssertEqual(try store.commitSceneWorkflowItem(small.header.id, assetID: row.id, qualify: qualification).state, .completed) }
        let elapsed20 = start20.duration(to: .now)
        let smallDone = try store.sceneWorkflow(id: small.header.id)
        XCTAssertEqual(Set(smallDone.items.compactMap(\.candidate)).count, 20)
        for row in smallDone.items {
            let version = try store.editingVersion(id: XCTUnwrap(row.candidate)), work = try store.photoWork(id: version.workID)
            XCTAssertEqual(work.originalVersionID, work.adoptedVersionID)
            XCTAssertNil(work.liveRecipe)
        }
        XCTAssertTrue(try store.undoSceneWorkflow(small.header.id).items.allSatisfy { $0.state == .undone })
        let large = try store.reviewSceneWorkflow(donorID: donor.id, targets: Array(files.dropFirst()).map(\.id), work: .exposure(1.5), basis: .original)
        try store.registerSceneWorkflow(large)
        let start200 = ContinuousClock.now
        for row in large.items.prefix(23) { XCTAssertEqual(try store.commitSceneWorkflowItem(large.header.id, assetID: row.id, qualify: qualification).state, .completed) }
        let cancelled = try store.cancelSceneWorkflow(large.header.id)
        XCTAssertEqual(cancelled.items.filter { $0.state == .cancelled }.count, 177)
        let first = try XCTUnwrap(cancelled.items.first?.candidate)
        store = try LibraryStore(databaseURL: db)
        XCTAssertEqual(try store.sceneWorkflowTemplates().first, template)
        XCTAssertEqual(try store.latestSceneWorkflow()?.id, large.header.id)
        XCTAssertEqual(try store.sceneWorkflow(id: large.header.id), cancelled)
        let late = large.items[27], replacementSource = try store.captureEditingSourceSnapshot(assetID: late.id)
        let changed = try store.createPhotoWork(source: replacementSource)
        _ = try store.saveLiveDevelopmentState(workID: changed.id, recipe: .init(exposureEV: 2), parentVersionID: changed.originalVersionID, expectedRevision: 0)
        let offline = files[35], moved = root.appending(path: "disconnected.ARW")
        try FileManager.default.moveItem(at: offline.resolvedURL, to: moved)
        let retry = try store.retrySceneWorkflow(large.header.id)
        for row in retry.items where row.state == .pending { _ = try store.commitSceneWorkflowItem(large.header.id, assetID: row.id, qualify: qualification) }
        var observed = try store.sceneWorkflow(id: large.header.id)
        XCTAssertEqual(observed.items.filter { $0.state == .completed }.count, 198)
        XCTAssertEqual(observed.items.first(where: { $0.id == late.id })?.state, .conflict)
        XCTAssertEqual(observed.items.first(where: { $0.id == offline.id })?.state, .offline)
        try FileManager.default.moveItem(at: moved, to: offline.resolvedURL)
        _ = try store.retrySceneWorkflow(large.header.id)
        XCTAssertEqual(try store.commitSceneWorkflowItem(large.header.id, assetID: offline.id, qualify: qualification).state, .completed)
        let elapsed200 = start200.duration(to: .now)
        observed = try store.sceneWorkflow(id: large.header.id)
        XCTAssertEqual(observed.items.filter { $0.state == .completed }.count, 199)
        XCTAssertEqual(observed.items.first?.candidate, first, "retry never regenerates a successful candidate")
        let firstVersion = try store.editingVersion(id: first), firstWork = try store.photoWork(id: firstVersion.workID)
        _ = try store.adoptEditingVersion(workID: firstWork.id, versionID: first, expectedRevision: firstWork.adoptionRevision)
        let undone = try store.undoSceneWorkflow(large.header.id)
        XCTAssertEqual(undone.items.filter { $0.state == .undone }.count, 198)
        XCTAssertEqual(undone.items.filter { $0.state == .conflict }.count, 2)
        XCTAssertEqual(try store.photoWork(id: firstWork.id).adoptedVersionID, first)
        XCTAssertEqual(try store.photoWork(id: changed.id).liveRecipe?.exposureEV, 2)
        XCTAssertEqual(try store.photoWork(id: donorWork.id), donorWork)
        XCTAssertEqual(try store.loadEditingVersions(workID: donorWork.id).count, 1)
        XCTAssertEqual(try FileSafety.hash(fixture), digest)
        XCTAssertEqual(qualified.count, 1)
        if let output = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BATCH_REPORT"] {
            @Sendable func seconds(_ duration: Duration) -> Double { Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18 }
            let report: [String: Any] = ["scope": "isolated SQLite workflow candidates with complete original rehash, fixed authorized RAW repeat across separately admitted projects; excluding export encoding and UI",
                "sourceSHA256": digest, "bytesPerSource": bytes, "smallTargetCount": 20, "largeTargetCount": 200,
                "seconds20": seconds(elapsed20), "seconds200": seconds(elapsed200), "partialBeforeCancel": 23,
                "completedAfterRetry": 199, "undoWithoutConflict": 198, "staleUndoProtected": true,
                "qualificationEvaluations": qualified.count, "os": ProcessInfo.processInfo.operatingSystemVersionString]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: URL(fileURLWithPath: output), options: [.withoutOverwriting])
            XCTAssertLessThanOrEqual(seconds(elapsed20), 15)
            XCTAssertLessThanOrEqual(seconds(elapsed200), 120)
        }
    }
}
