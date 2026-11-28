import Foundation
import XCTest
import RAWMasterLibrary
@testable import RAWMasterCore

final class LibraryImportArchiveTests: XCTestCase {
    func testImportBindsClockAndPairToIndependentCameraFilesAcrossReopen() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let fixture = env["RAWMASTER_TEST_RAW_JPEG_PAIR_DIR"], let sony = env["RAWMASTER_TEST_CLOCK_ARW"] else {
            throw XCTSkip("需要 006 的机内 DNG/JPEG 同快门对和已核验时区的 Sony ARW")
        }
        let fs = FileManager.default
        let root = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("camera")
        try fs.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: root) }
        let pairFiles = try fs.contentsOfDirectory(at: URL(fileURLWithPath: fixture), includingPropertiesForKeys: nil)
        for suffix in ["dng", "jpg"] {
            let original = try XCTUnwrap(pairFiles.first(where: { $0.pathExtension.lowercased() == suffix }))
            try fs.copyItem(at: original, to: source.appendingPathComponent("PAIR." + suffix))
        }
        try fs.copyItem(at: URL(fileURLWithPath: sony), to: source.appendingPathComponent("SONY.arw"))

        for mode in [ImportMode.reference, .copy] {
            let database = root.appendingPathComponent(mode.rawValue + ".sqlite")
            let store = try LibraryStore(databaseURL: database)
            let service = ImportService(store: store)
            let managed = mode == .copy ? root.appendingPathComponent("managed") : nil
            let session = try await service.importDirectory(source: source, destination: managed,
                projectName: mode.rawValue, mode: mode, initialScreening: true, progress: { _ in })
            XCTAssertEqual(session.completed, 3)
            let assets = Dictionary(uniqueKeysWithValues: try store.loadAssets(sessionID: session.id).map { ($0.filename, $0) })
            let dng = try XCTUnwrap(assets["PAIR.dng"]), jpeg = try XCTUnwrap(assets["PAIR.jpg"])
            let rawClock = try XCTUnwrap(dng.captureClock), jpegClock = try XCTUnwrap(jpeg.captureClock)
            XCTAssertNotNil(rawClock.localSecond)
            XCTAssertEqual(rawClock.localSecond, jpegClock.localSecond)
            XCTAssertNil(rawClock.offsetMinutes)
            XCTAssertNil(rawClock.nanosecond)
            XCTAssertTrue(CaptureClock.describesSameInstant(rawClock, jpegClock))
            let raw = try XCTUnwrap(assets["SONY.arw"])
            XCTAssertEqual(raw.captureClock?.offsetMinutes, 60)
            XCTAssertEqual(raw.captureClock?.displayText, "2018-03-13 16:38:13 +01:00")
            XCTAssertEqual(raw.capturedAt, ISO8601DateFormatter().date(from: "2018-03-13T15:38:13Z"))
            for asset in assets.values {
                XCTAssertEqual(try FileSafety.hash(asset.resolvedSourceURL), asset.contentHash)
                XCTAssertEqual(try FileSafety.hash(asset.resolvedURL), asset.contentHash)
            }
            let first = try XCTUnwrap(store.loadCapturePairs(sessionID: session.id).first)
            XCTAssertEqual(Set(first.assetIDs), Set([dng.id, jpeg.id]))
            XCTAssertFalse(first.isManual)
            let reopened = try LibraryStore(databaseURL: database)
            _ = try await ImportService(store: reopened).resume(sessionID: session.id, progress: { _ in })
            XCTAssertEqual(try reopened.loadCapturePairs(sessionID: session.id).map(\.id), [first.id])
            XCTAssertEqual(try reopened.loadAssets(sessionID: session.id).first(where: { $0.id == raw.id })?.captureClock, raw.captureClock)
        }
    }

    func testImportReadRejectsPathReplacementEvenWhenOpenedFileIsUnchanged() throws {
        let fs = FileManager.default
        let folder = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fs.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: folder) }
        let url = folder.appendingPathComponent("raw")
        let moved = folder.appendingPathComponent("moved")
        try Data("original".utf8).write(to: url)
        let initial = try FileSafety.hash(url)
        XCTAssertThrowsError(try FileSafety.withStableRegularFile(at: url) { handle, size in
            XCTAssertEqual(size, 8)
            try fs.moveItem(at: url, to: moved)
            try Data("replaced".utf8).write(to: url)
            XCTAssertEqual(try FileSafety.hash(handle), initial)
        }) { error in
            guard case LibraryError.sourceChanged = error else { return XCTFail("Unexpected error \(error)") }
        }
    }

    func testCaptureClockUsesIntegerPrecisionAcrossOffsetAndSecondBoundaries() {
        func time(_ date: String, _ fraction: String?, _ offset: String?) -> CaptureClock {
            CaptureClock(evidence: SequenceTimestampParser.parse(original: date, subseconds: fraction, offset: offset), invalidTagType: false)
        }
        let first = time("2026:11:29 00:00:00", "999500001", "+02:00")
        let next = "2026:11:28 22:00:01"
        XCTAssertTrue(CaptureClock.describesSameInstant(first, time(next, "000500000", "+00:00")))
        XCTAssertFalse(CaptureClock.describesSameInstant(first, time(next, "000500001", "+00:00")))
        XCTAssertFalse(CaptureClock.describesSameInstant(first, time(next, "000500002", "+00:00")))
        let coarse = time("2026:11:29 00:00:00", nil, nil)
        XCTAssertTrue(CaptureClock.describesSameInstant(first, coarse))
        XCTAssertFalse(CaptureClock.describesSameInstant(first, time("2026:11:29 00:00:00", nil, "+00:00")))
        XCTAssertFalse(CaptureClock.describesSameInstant(first, time("2026:11:29 00:00:00", nil, "unknown")))
    }

    func testCopyCannotPublishReplacedStagingFileAfterVerification() throws {
        let fs = FileManager.default
        let folder = fs.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fs.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fs.removeItem(at: folder) }
        let source = folder.appendingPathComponent("original")
        let target = folder.appendingPathComponent("verified-copy")
        let bytes = Data("original".utf8)
        try bytes.write(to: source)
        var publicationChecks = 0
        var replacement: URL?
        XCTAssertThrowsError(try FileSafety.verifiedCopy(source: source, target: target, expectedHash: nil,
            protectedRoots: [], beforePublish: {
                publicationChecks += 1
                guard publicationChecks == 3 else { return }
                let staged = try XCTUnwrap(fs.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
                    .first(where: { $0.pathExtension == "partial" }))
                try fs.moveItem(at: staged, to: folder.appendingPathComponent("original-staging"))
                try Data("replaced".utf8).write(to: staged)
                replacement = staged
            }, cancel: {}))
        XCTAssertEqual(publicationChecks, 3)
        XCTAssertFalse(fs.fileExists(atPath: target.path))
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(replacement)), Data("replaced".utf8))
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    func testOriginalDeliveryManifestKeepsPairingEvidenceInTheLibrary() throws {
        let date = Date(timeIntervalSince1970: 1_797_532_000)
        var asset = AssetRecord(sessionID: "s", projectID: "p", sourcePath: "/example/RAW.ARW", capturedAt: date)
        asset.captureClock = CaptureClock(evidence: SequenceTimestampParser.parse(
            original: "2026:11:29 00:00:00", subseconds: "005", offset: "+02:00"), invalidTagType: false)
        asset.cameraSerialDigest = String(repeating: "a", count: 64)
        let manifest = ExportManifest(status: "completed", sessions: [],
            items: [.init(asset: asset, copyRequested: false, status: "notRequested")])
        let output = try ExportService.manifestFiles(manifest, layout: .photoRows, allowedIDs: [asset.id], jsonName: "manifest.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let delivered = try XCTUnwrap(decoder.decode(ExportManifest.self, from: output.json).items.first?.asset)
        XCTAssertEqual(delivered.capturedAt, date)
        XCTAssertNil(delivered.captureClock)
        XCTAssertNil(delivered.cameraSerialDigest)
    }

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
