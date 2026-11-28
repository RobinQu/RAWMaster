import Foundation
@testable import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class DevelopmentSceneDeliveryServiceV1Tests: XCTestCase {
  typealias Delivery = DevelopmentSceneDeliveryV1
  typealias Service = DevelopmentSceneDeliveryServiceV1

  func testFrozenRequestRoundTripAndStrictVersionAndTarget() throws {
    let delivery = try makeDelivery(source: URL(fileURLWithPath: "/fixtures/snow.ARW"), byteCount: 5)
    let data = try JSONEncoder().encode(delivery)
    XCTAssertEqual(try JSONDecoder().decode(Delivery.self, from: data), delivery)
    let sdr = try delivery.rendition(.png16)
    XCTAssertEqual(try JSONDecoder().decode(Delivery.self, from: JSONEncoder().encode(sdr)), sdr)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    for fields: [String: Any] in [["schemaVersion": 2], ["target": "sdr709"], ["format": "jpeg8"], ["currentHeadroom": 2], ["previewNode": "first"]] {
      let changed = object.merging(fields) { _, new in new }
      XCTAssertThrowsError(try JSONDecoder().decode(Delivery.self, from: JSONSerialization.data(withJSONObject: changed)))
    }
  }

  func testRejectsReplacedSourceUnsupportedFormatAndProtectedDestinationBeforePublishing() async throws {
    let root = try tempDirectory()
    let source = root.appendingPathComponent("source.ARW"), target = root.appendingPathComponent("scene.avif")
    try Data("stale".utf8).write(to: source)
    let delivery = try makeDelivery(source: source, byteCount: 5)
    do {
      _ = try await Service.export(delivery, to: target)
      XCTFail("changed input cannot be delivered")
    } catch EditingError.staleSource {}
    do {
      _ = try await Service.export(delivery, to: target, protectedURLs: [root])
      XCTFail("protected path cannot be used")
    } catch DevelopmentError.protectedDestination {}
    do {
      _ = try await Service.export(delivery, to: root.appendingPathComponent("wrong.jpg"))
      XCTFail("wrong extension cannot be used")
    } catch Service.Failure.invalidDestination {}
    let other = try makeDelivery(source: root.appendingPathComponent("processed.jpg"), byteCount: 5)
    do {
      _ = try await Service.export(other, to: target)
      XCTFail("display referred input cannot be interpreted as scene RAW")
    } catch Service.Failure.unsupportedSource {}
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [source.lastPathComponent])
  }

  func testAuthorizedSnowRAWPublishesVerifiedAVIFWithoutReplacingDestination() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_DELIVERY_SNOW_ARW to the fixed, authorized 037 snow fixture")
    }
    let source = URL(fileURLWithPath: path)
    let count = try FileSafety.stat(source).size
    XCTAssertEqual(try RenderFiles.hash(source), Self.snowSHA256)
    let frozen = try makeDelivery(source: source, byteCount: count)
    let root = try tempDirectory()
    let target = root.appendingPathComponent("snow.avif")
    let receipt = try await Service.export(frozen, to: target)
    XCTAssertEqual(receipt.versionID, frozen.versionID)
    XCTAssertEqual(receipt.sourceSHA256, Self.snowSHA256)
    XCTAssertEqual(receipt.workflowSHA256, try frozen.program.fingerprint())
    XCTAssertEqual(receipt.target, .hdr2020)
    XCTAssertEqual(receipt.artifact.pixelWidth, 4000)
    XCTAssertEqual(receipt.artifact.pixelHeight, 6000)
    XCTAssertEqual(receipt.artifact.bitDepth, 10)
    XCTAssertEqual(receipt.artifact.alphaPolicy, .opaque)
    let signal = try DevelopmentSceneAVIFV1.readSignal(Data(contentsOf: target))
    XCTAssertEqual(signal.primaries, 9)
    XCTAssertEqual(signal.transfer, 16)
    XCTAssertTrue(signal.fullRange)
    XCTAssertEqual(signal.matrix, receipt.matrix)
    XCTAssertEqual(try RenderFiles.hash(target), receipt.artifact.sha256)
    do {
      _ = try await Service.export(frozen, to: target)
      XCTFail("existing file cannot be replaced")
    } catch DevelopmentError.outputExists {}
    XCTAssertEqual(try RenderFiles.hash(target), receipt.artifact.sha256)
    XCTAssertEqual(try RenderFiles.hash(source), Self.snowSHA256)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [target.lastPathComponent])
    try retainEvidence(target)
  }

  func testAuthorizedSnowPreparedStageRetainedAndSDRRenditionsVerifyOnDisk() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_DELIVERY_SNOW_ARW to the fixed, authorized 037 snow fixture")
    }
    enum PreparationError: Error { case interrupted }
    let source = URL(fileURLWithPath: path)
    let hdr = try makeDelivery(source: source, byteCount: FileSafety.stat(source).size)
    let root = try tempDirectory(), target = root.appendingPathComponent("interrupted.avif")
    let formats: [(Delivery.Format, Int)] = [(.jpeg8, 8), (.png16, 16)]
    var renditions: [Service.Rendition] = [.init(hdr, to: target, preparePublication: { stage, destination, artifact in
      XCTAssertEqual(destination, target)
      XCTAssertTrue(stage.lastPathComponent.hasPrefix(".rawmaster-render-"))
      XCTAssertEqual(try RenderFiles.hash(stage), artifact.sha256)
      XCTAssertEqual(try DevelopmentSceneAVIFV1.readSignal(Data(contentsOf: stage)).bitDepth, 10)
      throw PreparationError.interrupted
    })]
    for (format, _) in formats {
      let sdr = try hdr.rendition(format)
      let destination = root.appendingPathComponent("snow-share.\(format.filenameExtension)")
      renditions.append(.init(sdr, to: destination))
    }
    let results = try await Service.exportTogether(renditions)
    XCTAssertEqual(results.count, 3)
    XCTAssertThrowsError(try results[0].get()) { XCTAssertEqual($0 as? PreparationError, .interrupted) }
    let staged = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix(".rawmaster-render-") }
    XCTAssertEqual(staged.count, 1)
    XCTAssertTrue(staged.first?.lastPathComponent.hasSuffix(".avif") == true)
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    for (index, (format, depth)) in formats.enumerated() {
      let receipt = try results[index + 1].get(), destination = renditions[index + 1].destination
      XCTAssertEqual(receipt.workflowSHA256, try hdr.program.fingerprint())
      XCTAssertEqual(receipt.versionID, hdr.versionID)
      XCTAssertEqual(receipt.format, format)
      XCTAssertEqual(receipt.artifact.pixelWidth, 4000)
      XCTAssertEqual(receipt.artifact.pixelHeight, 6000)
      XCTAssertEqual(receipt.artifact.bitDepth, depth)
      XCTAssertNotNil(receipt.artifact.iccProfileSHA256)
      XCTAssertNil(receipt.matrix)
      XCTAssertEqual(try RenderFiles.hash(destination), receipt.artifact.sha256)
      try retainEvidence(destination)
    }
    XCTAssertEqual(try RenderFiles.hash(source), Self.snowSHA256)
  }

  func testCancelledTaskNeverEntersRenderingOrLeavesAStage() async throws {
    let root = try tempDirectory(), target = root.appendingPathComponent("cancel.avif")
    let delivery = try makeDelivery(source: URL(fileURLWithPath: "/fixtures/snow.ARW"), byteCount: 5)
    let task = Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return try await Service.export(delivery, to: target, preparePublication: { _, _, _ in XCTFail("cancelled request prepared publication") })
    }
    do {
      _ = try await task.value
      XCTFail("cancelled request rendered")
    } catch is CancellationError {}
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
  }

  func testOptInPersistedSceneGraphReopensAndRendersTheFrozenFinalBeforeAndAfterLiveChanges() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_SNOW_ARW"] else {
      throw XCTSkip("Set RAWMASTER_SCENE_DELIVERY_SNOW_ARW to the fixed, authorized 037 snow fixture")
    }
    try await verifyFrozenGraph(path: path, hash: Self.snowSHA256, name: "snow", width: 4000, height: 6000)
  }

  func testOptIn60MPFrozenGraphExportsFullPQAndSDRWithinBudget() async throws {
    guard let path = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_60MP_ARW"] else {
      throw XCTSkip("Supply the authorized 60 MP DSC05995 ARW")
    }
    try await verifyFrozenGraph(path: path, hash: "7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89",
      name: "DSC05995", width: 9504, height: 6336)
  }

  func testOptInPhotographic60MPFrozenGraphPublishesPQTogetherWithTheEditedSDRDerivative() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard let path = environment["RAWMASTER_SCENE_60MP_ARW"] else {
      throw XCTSkip("Supply the authorized 60 MP DSC05995 ARW")
    }
    let repeats = Int(environment["RAWMASTER_SCENE_DELIVERY_PROFILE_REPEATS"] ?? "1") ?? 0
    guard (1...64).contains(repeats) else { return XCTFail("Profile repeats must be from 1 through 64") }
    var adjustments = DevelopmentAdjustmentsV3()
    adjustments.light = .init(enabled: true, exposure: 0.25)
    adjustments.color = .init(enabled: true, saturation: 0.32, vibrance: -0.15)
    for run in 0..<repeats {
      let name = repeats == 1 ? "DSC05995-photographic" : "DSC05995-photographic-\(run)"
      try await verifyFrozenGraph(path: path, hash: "7798bebb0b45d68e44d5794385eeb361498858e4f477d9f658a066c41786dc89",
        name: name, width: 9504, height: 6336, photographic: adjustments)
    }
  }

  private func verifyFrozenGraph(path: String, hash: String, name: String, width: Int, height: Int, photographic: DevelopmentAdjustmentsV3? = nil) async throws {
    typealias Graph = DevelopmentSceneGraphV1
    let backend: DevelopmentSceneExecutionReceiptV1.Backend =
      ProcessInfo.processInfo.environment["RAWMASTER_SCENE_BACKEND"]?.lowercased() == "wgpu" ? .wgpu : .rust
    let root = try tempDirectory(), database = root.appendingPathComponent("library.sqlite")
    let sourceURL = URL(fileURLWithPath: path)
    let sourceHash = try FileSafety.hash(sourceURL), count = try FileSafety.stat(sourceURL).size
    XCTAssertEqual(sourceHash, hash)
    var store = try LibraryStore(databaseURL: database)
    let project = ProjectRecord(name: "Scene graph acceptance")
    try store.saveProject(project)
    let session = ImportSession(projectID: project.id, projectName: project.name,
      sourcePath: sourceURL.deletingLastPathComponent().path, mode: .reference, status: "completed", discovered: 1,
      completed: 1, scanCompleted: true)
    try store.saveSession(session)
    let asset = try store.register(.init(sessionID: session.id, projectID: project.id, sourcePath: sourceURL.path,
      fileSize: count, contentHash: sourceHash, importState: .ready))
    try store.completedDirectImport(session)
    let source = try store.captureEditingSourceSnapshot(assetID: asset.id), work = try store.createPhotoWork(source: source)
    let base = try store.editingVersion(id: work.originalVersionID)
    XCTAssertThrowsError(try store.freezeSceneDelivery(versionID: base.id, format: .avif10))
    let baseJSON = try EditingFingerprint.of(base.recipe)
    let mask = Graph.Node(name: "Snow to dusk", operation: .linearCoverage(start: .init(0.15, 0), end: .init(0.85, 0)))
    let bright = Graph.Node(name: "Lift", operation: .corrector(image: .input, mask: mask.id, exposureEV: 1,
      curve: [], strength: 1, enabled: true))
    let mix = Graph.Node(name: "Layer", operation: .layer(base: .input,
      layers: [.init(.node(bright.id), weight: 0.5)], enabled: true))
    let output = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
    let graph = try Graph(graph: .init(nodes: [bright, mix, mask], output: .node(mix.id)), output: output, photographic: photographic)
    let candidate = try store.appendEditingVersion(.init(workID: work.id, parentVersionID: base.id, kind: .development,
      source: source, recipe: .init(sceneGraph: graph)))
    let initial = try store.freezeSceneDelivery(versionID: candidate.id, format: .avif10)
    let newDraft = try Graph(graph: .init(nodes: [], output: .input), output: output)
    _ = try store.saveLiveDevelopmentState(workID: work.id, recipe: .init(sceneGraph: newDraft), parentVersionID: candidate.id, expectedRevision: 0)
    XCTAssertThrowsError(try store.saveLiveDevelopmentState(workID: work.id, recipe: .init(sceneGraph: graph), parentVersionID: candidate.id, expectedRevision: 0))
    store = try LibraryStore(databaseURL: database)
    let frozen = try store.freezeSceneDelivery(versionID: candidate.id, format: .avif10)
    XCTAssertEqual(initial, frozen)
    XCTAssertEqual(try frozen.program.fingerprint(), try EditingFingerprint.of(candidate.recipe))
    XCTAssertEqual(try store.photoWork(id: work.id).liveRecipe?.sceneGraph, newDraft)
    XCTAssertEqual(try EditingFingerprint.of(store.editingVersion(id: base.id).recipe), baseJSON)
    let decoded = try JSONDecoder().decode(Delivery.self, from: JSONEncoder().encode(frozen))
    XCTAssertEqual(decoded, frozen)
    let target = root.appendingPathComponent(name + "-scene-graph.avif")
    let rendition = root.appendingPathComponent(name + "-scene-graph.jpg")
    let start = DispatchTime.now().uptimeNanoseconds
    let files = try await Service.exportTogether([.init(decoded, to: target), .init(try decoded.rendition(.jpeg8), to: rendition)])
    let hdr = try files[0].get(), sdr = try files[1].get()
    XCTAssertEqual(hdr.workflowSHA256, sdr.workflowSHA256)
    XCTAssertEqual(hdr.artifact.sha256, try RenderFiles.hash(target))
    XCTAssertEqual(hdr.versionID, sdr.versionID)
    XCTAssertEqual(hdr.artifact.bitDepth, 10)
    XCTAssertNotNil(sdr.artifact.iccProfileSHA256)
    let receipts = try [hdr, sdr].map { receipt in
      XCTAssertEqual(receipt.artifact.pixelWidth, width); XCTAssertEqual(receipt.artifact.pixelHeight, height)
      let execution = try XCTUnwrap(receipt.execution)
      XCTAssertEqual(execution.backend, photographic == nil ? backend : .mixed); XCTAssertNil(execution.fallbackReason)
      if photographic != nil { XCTAssertEqual(execution.dagBackend, backend); XCTAssertNotNil(execution.photographicEngine) }
      XCTAssertGreaterThan(execution.dispatches, 0)
      XCTAssertLessThanOrEqual(execution.peakBytes, execution.budgetBytes)
      if width == 9504 { XCTAssertGreaterThan(execution.tiles, 1) }
      return execution
    }
    XCTAssertEqual(try FileSafety.hash(sourceURL), sourceHash)
    try retainEvidence(target); try retainEvidence(rendition)
    if let directory = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_EVIDENCE"] {
      let url = URL(fileURLWithPath: directory).appendingPathComponent(name + "-scene-graph.json")
      let report: [String: Any] = ["sha256": hash, "versionID": hdr.versionID.uuidString, "workflowSHA256": hdr.workflowSHA256,
        "workflowNodes": graph.graph.nodes.count, "size": [width, height], "artifactSHA256": [hdr.artifact.sha256, sdr.artifact.sha256],
        "artifactBytes": [hdr.artifact.byteCount, sdr.artifact.byteCount], "targets": [hdr.target.rawValue, sdr.target.rawValue],
        "execution": try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipts)),
        "elapsedMs": Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6]
      try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .withoutOverwriting)
    }
  }

  private func retainEvidence(_ file: URL) throws {
    guard let directory = ProcessInfo.processInfo.environment["RAWMASTER_SCENE_DELIVERY_EVIDENCE"] else { return }
    try FileManager.default.copyItem(at: file, to: URL(fileURLWithPath: directory).appendingPathComponent(file.lastPathComponent))
  }

  private static let snowSHA256 = "ba70e98cc4b7caf453aaf96f6b9da3f28a460d07aec992a2c6a49a93f90f5af2"

  private func makeDelivery(source: URL, byteCount: Int64) throws -> Delivery {
    let snapshot = EditingSourceSnapshot(projectID: "scene-fixtures", assetID: "snow", contentSHA256: Self.snowSHA256,
      byteCount: byteCount, admissionFingerprint: String(repeating: "a", count: 64), sourceLocation: source)
    let output = DevelopmentSceneOutputStateV1.Version(sdrTrim: try .init(exposureEV: 0, mapping: .balanced, highlightCompression: 0))
    let workflow = try DevelopmentSceneWorkflowV1(correctors: [.init(exposureEV: 0.5), .init(exposureEV: 0.5)], output: output)
    return try Delivery(source: snapshot, versionID: UUID(), workflow: workflow, target: .hdr2020)
  }

  private func tempDirectory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SceneDelivery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }
}
