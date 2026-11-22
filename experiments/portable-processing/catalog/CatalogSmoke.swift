import CryptoKit
import Foundation
import RMQueueProbe
import SQLite3

typealias Object = [String: Any]
struct ProbeError: Error { let message: String }
func require(_ value: Bool, _ message: String) throws {
    if !value { throw ProbeError(message: message) }
}

// Use the production C loader. It checks that Swift and the dylib share sqlite3.
func catalog(_ runtime: OpaquePointer, _ command: Object, db: OpaquePointer? = nil, path: String = "") throws -> Object {
    let input = try JSONSerialization.data(withJSONObject: command)
    var reply = RMHostReply()
    let code: Int32 = input.withUnsafeBytes { raw in
        let bytes = raw.bindMemory(to: UInt8.self)
        if let db {
            return rm_host_transaction(runtime, UnsafeMutableRawPointer(db), bytes.baseAddress, bytes.count, &reply)
        }
        return Array(path.utf8).withUnsafeBufferPointer { location in
            rm_host_request(runtime, location.baseAddress, location.count, bytes.baseAddress, bytes.count, &reply)
        }
    }
    defer { rm_host_release(runtime, &reply) }
    guard let address = reply.data else { throw ProbeError(message: "missing catalog reply") }
    let data = Data(bytes: address, count: reply.length)
    guard code == 0, let value = try JSONSerialization.jsonObject(with: data) as? Object else {
        throw ProbeError(message: String(decoding: data, as: UTF8.self))
    }
    return value
}

func queue(_ path: String, _ request: Object) throws -> Object {
    let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
    guard let pointer = path.withCString({ file in body.withCString { rmq_request_v1(file, $0) } }) else {
        throw ProbeError(message: "missing queue reply")
    }
    defer { rmq_release_v1(pointer) }
    let data = Data(String(cString: pointer).utf8)
    guard let reply = try JSONSerialization.jsonObject(with: data) as? Object,
          reply["ok"] as? Bool == true, let value = reply["value"] as? Object else {
        throw ProbeError(message: String(decoding: data, as: UTF8.self))
    }
    return value
}

func run(_ runtime: OpaquePointer, _ root: URL, legacy: URL, jpeg: URL) throws -> Object {
    let bytes = try Data(contentsOf: jpeg)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let project = "swift-project", asset = "asset0000"
    let catalogURL = root.appendingPathComponent("production.sqlite")
    var handle: OpaquePointer?
    try require(sqlite3_open(catalogURL.path, &handle) == SQLITE_OK, "open private catalog")
    guard let handle else { throw ProbeError(message: "missing SQLite connection") }
    defer { sqlite3_close(handle) }
    func sql(_ text: String) throws {
        try require(sqlite3_exec(handle, text, nil, nil, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(handle)))
    }
    func literal(_ object: Object) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return "'" + String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''") + "'"
    }
    // One closed, admitted v7 photo, using the production migration fixture schema.
    try sql("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON; BEGIN IMMEDIATE")
    try sql(String(contentsOf: legacy, encoding: .utf8))
    let session: Object = ["id":"s", "projectID":project, "mode":"reference", "sourcePath":jpeg.deletingLastPathComponent().path,
                           "status":"completed", "scanCompleted":true]
    let photo: Object = ["id":asset, "sessionID":"s", "projectID":project, "filename":jpeg.lastPathComponent,
                         "currentPath":jpeg.path, "sourcePath":jpeg.path, "relativePath":jpeg.lastPathComponent,
                         "contentHash":digest, "fileSize":bytes.count, "rating":0, "decision":"keep",
                         "availability":"available", "importState":"ready"]
    try sql("INSERT INTO projects VALUES('swift-project',\(try literal(["id":project,"name":"Swift proof"])))")
    try sql("INSERT INTO sessions VALUES('s',\(try literal(session)))")
    try sql("INSERT INTO assets(id,session_id,source_path,data) VALUES('asset0000','s','fixture',\(try literal(photo)))")
    try sql("INSERT INTO session_workflows VALUES('s',\(try literal(["sessionID":"s","phase":"legacyHistory","projectID":project,"importActive":false])))")
    try sql("INSERT INTO project_admissions VALUES('asset0000',\(try literal(["assetID":asset,"projectID":project,"sequenceOnly":false])))")
    _ = try catalog(runtime, ["operation":"install"], db: handle)
    try sql("PRAGMA user_version=8; COMMIT")
    let overview = try catalog(runtime, ["operation":"overview"], path: catalogURL.path)
    let page = try catalog(runtime, ["operation":"page", "indexPath":root.appendingPathComponent("index.sqlite").path,
                                     "request":["projectID":project, "includeOrderedIDs":true, "pageSize":1]], path: catalogURL.path)
    guard overview["files"] as? Int == 1, let ids = page["orderedAssetIDs"] as? [String], ids == [asset],
          let library = page["libraryID"] as? String else { throw ProbeError(message: "production page mismatch: \(page)") }
    let frozen: Object = ["libraryID":library, "assetID":ids[0], "contentSHA256":digest, "revision":1]
    let temporaryQueue = root.appendingPathComponent("queue.sqlite").path
    try require(rmq_abi_version() == 1, "queue ABI")
    _ = try queue(temporaryQueue, ["op":"submit", "key":"swift-1", "lane":"library", "resource":"io", "payload":frozen])
    let lease = try queue(temporaryQueue, ["op":"claim"])
    guard let token = lease["token"] as? String, let payload = lease["payload"] as? Object,
          payload["contentSHA256"] as? String == digest else { throw ProbeError(message: "lease lost frozen input") }
    let receipt = try queue(temporaryQueue, ["op":"complete", "key":"swift-1", "token":token, "file":jpeg.path, "result":digest])
    try require(receipt["state"] as? String == "done" && receipt["resourceID"] as? String == "job:swift-1", "missing registration")
    try require(try queue(temporaryQueue, ["op":"status", "key":"swift-1"])["result"] as? String == digest, "missing stored SHA")
    return ["catalogSchema":8, "productionOverviewFiles":overview["files"]!, "pagedAssetIDs":ids, "fixtureSHA256":digest,
            "queuedFrozenAssetID":payload["assetID"]!, "resourceID":receipt["resourceID"]!, "state":receipt["state"]!,
            "queueABI":rmq_abi_version(), "sqlite":String(cString: sqlite3_libversion())]
}

func smoke() throws -> Object {
    let args = CommandLine.arguments
    try require(args.count == 4, "usage: CatalogSmoke <production catalog dylib> <legacy schema.sql> <fixture.jpg>")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    var message: UnsafeMutablePointer<CChar>?
    guard let runtime = args[1].withCString({ rm_host_open($0, &message) }) else {
        defer { rm_host_free_message(message) }
        throw ProbeError(message: message.map { String(cString:$0) } ?? "could not load the production core")
    }
    defer { rm_host_close(runtime) }
    return try run(runtime, root, legacy: URL(fileURLWithPath: args[2]), jpeg: URL(fileURLWithPath: args[3]))
}

let report = try JSONSerialization.data(withJSONObject: smoke(), options: [.prettyPrinted, .sortedKeys])
print(String(decoding: report, as: UTF8.self))
