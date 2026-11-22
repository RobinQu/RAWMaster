import Foundation
import XCTest
import RAWMasterLibrary
@testable import RAWMasterCore

final class LibraryImportArchiveTests: XCTestCase {
    func testExistingCatalogOpensForBrowsingWhileAnotherConnectionHoldsTheWriter() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:folder) }
        let url = folder.appendingPathComponent("library.sqlite")
        let writer = try LibraryStore(databaseURL:url)
        try writer.exec("BEGIN IMMEDIATE")
        defer { try? writer.exec("ROLLBACK") }
        let reader = try LibraryStore(databaseURL:url)
        XCTAssertEqual(reader.deviceID,writer.deviceID)
        XCTAssertTrue(try reader.loadAdmissions().isEmpty)
    }

    func testImportCompletionControlsPhysicalBackupAndRestoredLibrary() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["RAWMASTER_RUNTIME_RAW_DIRECTORY"], let preview = env["RAWMASTER_LIBRARY_CAMERA_JPEG"] else {
            throw XCTSkip("需要实拍 RAW 和同次拍摄的机内 JPEG")
        }
        let fm = FileManager.default
        let samples = try fm.contentsOfDirectory(at: URL(fileURLWithPath:dir),includingPropertiesForKeys:nil)
            .filter { $0.pathExtension.lowercased() == "arw" }.sorted { $0.path < $1.path }
        XCTAssertGreaterThanOrEqual(samples.count,4)
        guard samples.count >= 4 else { return }
        let root = fm.temporaryDirectory.appendingPathComponent("library-admission-" + UUID().uuidString)
        let card = root.appendingPathComponent("card")
        try fm.createDirectory(at:card,withIntermediateDirectories:true)
        defer { try? fm.removeItem(at:root) }
        for (name, source) in [("A.ARW",samples[0]),("A.JPG",URL(fileURLWithPath:preview)),("B.ARW",samples[1]),("C.ARW",samples[2]),("D.ARW",samples[3])] {
            try fm.copyItem(at:source,to:card.appendingPathComponent(name))
        }
        let url = root.appendingPathComponent("library.sqlite")
        let store = try LibraryStore(databaseURL:url)
        let session = try await ImportService(store:store).importDirectory(source:card,destination:nil,projectName:"实拍",mode:.reference,initialScreening:true,progress:{ _ in })
        let all = Dictionary(uniqueKeysWithValues:try store.loadAssets(sessionID:session.id).map { ($0.filename,$0) })
        let raw = try XCTUnwrap(all["A.ARW"]), jpg = try XCTUnwrap(all["A.JPG"]), b = try XCTUnwrap(all["B.ARW"]), c = try XCTUnwrap(all["C.ARW"])
        var d = try XCTUnwrap(all["D.ARW"])
        _ = try store.confirmCapturePair(rawAssetID:raw.id,jpegAssetID:jpg.id)
        try store.createGroup(ids:[raw.id,b.id,c.id],name:"间隔拍摄",kind:"延时")
        _ = try store.updateTriage(ids:[raw.id,c.id],disposition:.excluded)
        d.contentHash = nil; d.importState = .failed
        try store.saveImportAsset(d)
        let members = try store.completionMembers(sessionID:session.id)
        let marker = try XCTUnwrap(members.first { $0.assetID == b.id })
        let draft = try store.previewCompletion(sessionID:session.id,acknowledgeManualAnalysis:true,dispositions:[marker.id:.sequenceOnly],confirmedFailures:true)
        XCTAssertEqual(Set(draft.admittedAssetIDs),Set([b.id,jpg.id]))
        XCTAssertEqual(Set(draft.excludedAssetIDs),Set([raw.id,c.id]))
        XCTAssertEqual(draft.failedAssetIDs,[d.id])
        _ = try store.commitCompletion(draft)
        XCTAssertEqual(try store.commitCompletion(draft).phase, .closed)
        let reopened = try LibraryStore(databaseURL:url)
        XCTAssertEqual(Set(try reopened.loadAdmissions().map(\.assetID)),Set([b.id,jpg.id]))
        let package = root.appendingPathComponent("generation")
        let actions = reopened.catalogActions
        let result = try await actions.read("package", ["op":.string("backup"),"mode":.string("full"),"destination":.string(package.path)])
        XCTAssertEqual(result["state"]?.stringValue,"complete")
        let objects = package.appendingPathComponent("objects")
        let hashes = try fm.contentsOfDirectory(at:objects,includingPropertiesForKeys:nil).flatMap { try fm.contentsOfDirectory(at:$0,includingPropertiesForKeys:nil) }.map { try FileSafety.hash($0) }
        XCTAssertEqual(Set(hashes),Set(try [XCTUnwrap(b.contentHash),XCTUnwrap(jpg.contentHash)]))
        try fm.moveItem(at:card,to:root.appendingPathComponent("detached"))
        let restored = root.appendingPathComponent("restored")
        let receipt = try await actions.read("package",["op":.string("restore"),"package":.string(package.path),"destination":.string(restored.path)])
        let restoredDB = try XCTUnwrap(receipt["libraryPath"]?.stringValue)
        let copy = try LibraryStore(databaseURL:URL(fileURLWithPath:restoredDB))
        XCTAssertEqual(Set(try copy.loadAdmissions().map(\.assetID)),Set([b.id,jpg.id]))
        let remounted = try copy.loadAssets().filter { [b.id,jpg.id].contains($0.id) }
        XCTAssertEqual(Set(try remounted.map { try FileSafety.hash($0.resolvedURL) }),Set(hashes))
    }
}
