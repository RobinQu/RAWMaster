import Foundation
import CryptoKit
import XCTest
@testable import RAWMasterCore

final class PairScanPerformanceTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("RAWMasterPairScan-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func record(_ path: String, session: ImportSession, root: URL) -> AssetRecord {
        let bytes = Data(path.utf8)
        let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        return AssetRecord(sessionID: session.id, projectID: session.projectID,
            sourcePath: root.appendingPathComponent(path).path, relativePath: path,
            fileSize: Int64(bytes.count),
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000), camera: "Camera",
            width: 6000, height: 4000, contentHash: hash, importState: .ready)
    }

    func testAutomaticPairScanPreservesManualDismissedAmbiguousAndMetadataRules() throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let session = try store.prepareImportSession(root: root, destination: nil, mode: .reference,
            projectName: "Pairs", projectID: nil, initialScreening: true)
        var records: [AssetRecord] = []
        for prefix in ["manual", "dismissed", "automatic", "nested/automatic", "ambiguous", "pending", "camera", "time", "size"] {
            records += [record(prefix + ".arw", session: session, root: root), record(prefix + ".jpg", session: session, root: root)]
        }
        records.append(record("ambiguous.dng", session: session, root: root))
        for i in records.indices {
            switch records[i].relativePath {
            case "pending.jpg": records[i].importState = .discovered
            case "camera.jpg": records[i].camera = "Other camera"
            case "time.jpg": records[i].capturedAt = Date(timeIntervalSince1970: 1_700_000_001)
            case "size.jpg": records[i].width = 3000
            default: break
            }
        }
        try store.registerDiscovered(records)
        let byPath = Dictionary(uniqueKeysWithValues: records.map { ($0.relativePath, $0) })
        let manual = try store.confirmCapturePair(rawAssetID: byPath["manual.arw"]!.id, jpegAssetID: byPath["manual.jpg"]!.id)
        try store.transaction {
            try store.statement("INSERT INTO pair_dismissals VALUES(?,?)", [store.pairKey(byPath["dismissed.arw"]!.id, byPath["dismissed.jpg"]!.id), "{}"])
        }
        let initialRevision = try XCTUnwrap(store.workflow(session.id)?.revision)
        let pairs = try store.scanCapturePairs(sessionID: session.id)
        XCTAssertEqual(pairs.count, 3)
        XCTAssertEqual(pairs.first?.id, manual.id)
        XCTAssertTrue(pairs.first?.isManual == true)
        XCTAssertEqual(Set(pairs.dropFirst().map(\.rawAssetID)), Set([byPath["automatic.arw"]!.id, byPath["nested/automatic.arw"]!.id]))
        XCTAssertTrue(pairs.dropFirst().allSatisfy { !$0.isManual })
        XCTAssertEqual(try store.workflow(session.id)?.revision, initialRevision + 2)
        let rerun = try store.scanCapturePairs(sessionID: session.id)
        XCTAssertEqual(rerun.map(\.id), pairs.map(\.id))
        XCTAssertEqual(try store.workflow(session.id)?.revision, initialRevision + 2)
        XCTAssertEqual(try store.rows("SELECT id FROM pair_dismissals").count, 1)
    }

    /// Metadata-only scan benchmark. It excludes original file reads and image decoding.
    func testOptionalLargePairScanBenchmark() throws {
        guard let output = ProcessInfo.processInfo.environment["RAWMASTER_PAIR_BENCHMARK_OUTPUT"] else {
            throw XCTSkip("Opt-in pair scan benchmark")
        }
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = try LibraryStore(databaseURL: root.appendingPathComponent("library.sqlite"))
        let session = try store.prepareImportSession(root: root, destination: nil, mode: .reference,
            projectName: "Pair benchmark", projectID: nil, initialScreening: true)
        let count = 1500
        try store.transaction {
            for i in 0..<count {
                for ext in ["arw", "jpg"] {
                    let value = record(String(format: "%05d", i) + "." + ext, session: session, root: root)
                    try store.statement("INSERT INTO assets(id,session_id,source_path,data) VALUES(?,?,?,?)", [value.id, value.sessionID, value.sourcePath, try store.json(value)])
                }
            }
        }
        let initialRevision = try XCTUnwrap(store.workflow(session.id)?.revision)
        let start = ProcessInfo.processInfo.systemUptime
        let pairs = try store.scanCapturePairs(sessionID: session.id)
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        XCTAssertEqual(pairs.count, count)
        XCTAssertEqual(Set(pairs.flatMap(\.assetIDs)).count, count * 2)
        XCTAssertEqual(try store.workflow(session.id)?.revision, initialRevision + count)
        let repeatStart = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(try store.scanCapturePairs(sessionID: session.id).map(\.id), pairs.map(\.id))
        let repeatSeconds = ProcessInfo.processInfo.systemUptime - repeatStart
        XCTAssertEqual(try store.workflow(session.id)?.revision, initialRevision + count)
        let result: [String: Any] = ["configuration": "debug", "assetCount": count * 2,
            "pairCount": count, "initialScanSeconds": elapsed, "idempotentRescanSeconds": repeatSeconds,
            "note": "Isolated metadata-only RAW+JPEG pairing; no original I/O or image decoding"]
        let url = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: url)
        print("PAIR_BENCHMARK " + String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
    }
}
