import Foundation
import XCTest
@testable import RAWMasterCore

final class OriginalDeliveryTests: XCTestCase {
  private func workspace() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterOriginalDelivery-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: url) }
    return url.resolvingSymlinksInPath()
  }

  func testPauseAndResumeReuseTheFrozenPathsAndRejectAReplacementTarget() async throws {
    let root = try workspace()
    let source = root.appendingPathComponent("Camera")
    let destination = root.appendingPathComponent("Output")
    for directory in [source, destination] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    try Data("first original".utf8).write(to: source.appendingPathComponent("A.ARW"))
    try Data("second original".utf8).write(to: source.appendingPathComponent("B.ARW"))
    let database = root.appendingPathComponent("library.sqlite")
    let store = try LibraryStore(databaseURL: database)
    let session = try await ImportService(store: store).importDirectory(source: source, destination: nil,
      projectName: "Originals", mode: .reference) { _ in }
    let assets = try store.loadAssets(sessionID: session.id)
    let first = try XCTUnwrap(assets.first { $0.filename == "A.ARW" })
    let sameName = destination.appendingPathComponent("RAWMaster精选/" + session.id + "/A.ARW")
    try FileManager.default.createDirectory(at: sameName.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("previous export".utf8).write(to: sameName)
    let original = ExportService(store: store)
    let job = try original.enqueueOriginalDelivery(id: UUID(), ids: assets.map(\.id), destination: destination,
      manifestIDs: assets.map(\.id), formats: .allOriginals, csvLayout: .photoRows)
    let paused = try await original.resumeOriginalDelivery(id: job.id) { progress in
      if progress.completed == 1 { original.pauseOriginalDelivery() }
    }
    XCTAssertEqual(paused.phase, .paused)
    XCTAssertEqual(paused.completed, 1)
    XCTAssertTrue(paused.report.manifestPath.isEmpty)

    let moved = root.appendingPathComponent("Output Renamed")
    try FileManager.default.moveItem(at: destination, to: moved)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
    let reopened = try LibraryStore(databaseURL: database)
    let reloaded = ExportService(store: reopened)
    let unavailable = try await reloaded.resumeOriginalDelivery(id: job.id) { _ in }
    XCTAssertEqual(unavailable.phase, .waiting)
    XCTAssertEqual(unavailable.completed, 1)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.path), [])

    let finished = try await reloaded.resumeOriginalDelivery(id: job.id, destination: moved) { _ in }
    XCTAssertEqual(finished.phase, .completed)
    XCTAssertEqual(finished.report.copied, assets.count)
    XCTAssertEqual(try reopened.originalDeliveryHistory().map(\.id), [job.id])
    let json = URL(fileURLWithPath: finished.report.manifestPath)
    let csv = json.deletingPathExtension().appendingPathExtension("csv")
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: json))
    let firstReceipt = try XCTUnwrap(manifest.items.first { $0.asset.id == first.id })
    let firstPublished = URL(fileURLWithPath: try XCTUnwrap(firstReceipt.outputPath))
    XCTAssertEqual(firstPublished.lastPathComponent, "A-1.ARW")
    XCTAssertEqual(try Data(contentsOf: firstPublished), try Data(contentsOf: first.resolvedURL))
    XCTAssertEqual(try Data(contentsOf: moved.appendingPathComponent("RAWMaster精选/" + session.id + "/A.ARW")), Data("previous export".utf8))
    let before = try String(contentsOf: csv, encoding: .utf8)
    let repeatJob = try await reloaded.resumeOriginalDelivery(id: job.id) { _ in }
    XCTAssertEqual(repeatJob.report.manifestPath, json.path)
    XCTAssertEqual(try String(contentsOf: csv, encoding: .utf8), before)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: firstPublished.deletingLastPathComponent().path).count, 3)
  }

  func testCopyRetainsManifestJobAsReadOnlyHistory() async throws {
    let root = try workspace()
    let camera = root.appendingPathComponent("Camera")
    try FileManager.default.createDirectory(at: camera, withIntermediateDirectories: false)
    let source = camera.appendingPathComponent("Photo.jpg")
    try Data("photo".utf8).write(to: source)
    let original = try LocalLibraryPackage.create(at: root.appendingPathComponent("Original"))
    let job: OriginalDeliveryJob
    do {
      let writer = try original.acquireWriter()
      let store = try writer.openStore()
      _ = try store.admitLightroomOriginal(source, projectID: nil)
      let photo = try XCTUnwrap(store.loadAssets().first)
      job = try ExportService(store: store).enqueueOriginalDelivery(id: UUID(), ids: [],
        destination: root.appendingPathComponent("Output"), manifestIDs: [photo.id], formats: .allOriginals,
        csvLayout: .photoRows)
    }
    let copy = root.appendingPathComponent("Copy.rawmasterlibrary")
    try FileManager.default.copyItem(at: original.root, to: copy)
    let writer = try LocalLibraryPackage.inspect(copy).acquireWriter()
    _ = try writer.prepare(.independentCopy)
    let store = try writer.openStore()
    let history = try XCTUnwrap(store.originalDeliveryHistory().first)
    XCTAssertTrue(history.historical)
    XCTAssertEqual(history.id, job.id)
    let service = ExportService(store: store)
    XCTAssertThrowsError(try service.cancelOriginalDelivery(id: history.id))
    do {
      _ = try await service.resumeOriginalDelivery(id: history.id) { _ in }
      XCTFail("A copied task must have no execution authority.")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("副本"))
    }
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: job.destinationPath), [])
    let sourceWriter = try original.acquireWriter()
    let sourceStore = try sourceWriter.openStore()
    XCTAssertFalse(try sourceStore.originalDeliveryJob(id: job.id).historical)
    let result = try await ExportService(store: sourceStore).resumeOriginalDelivery(id: job.id) { _ in }
    XCTAssertEqual(result.phase, .completed)
    XCTAssertEqual(result.report.copied, 0)
    XCTAssertFalse(result.report.manifestPath.isEmpty)
  }
}
