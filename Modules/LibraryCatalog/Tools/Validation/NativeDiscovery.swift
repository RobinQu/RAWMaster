import CryptoKit
import Foundation
import SQLite3

struct TestFailure: Error {
  let message: String
  init(_ message: String) { self.message = message }
}
func check(_ ok: Bool, _ m: String) throws { if !ok { throw TestFailure(m) } }
func sql(_ db: OpaquePointer, _ s: String) throws {
  if sqlite3_exec(db, s, nil, nil, nil) != SQLITE_OK {
    throw TestFailure(String(cString: sqlite3_errmsg(db)))
  }
}
func write(_ path: URL, _ body: (OpaquePointer) throws -> CatalogJSON) throws -> CatalogJSON {
  var db: OpaquePointer?
  guard sqlite3_open(path.path, &db) == SQLITE_OK, let db else { throw TestFailure("open") }
  defer { sqlite3_close(db) }
  try sql(db, "PRAGMA foreign_keys=ON;BEGIN IMMEDIATE")
  do {
    let out = try body(db)
    try sql(db, "COMMIT")
    return out
  } catch {
    try? sql(db, "ROLLBACK")
    throw error
  }
}
@main struct Smoke {
  static func main() async throws {
    let args = CommandLine.arguments
    let base = URL(fileURLWithPath: args[1])
    let pack = URL(fileURLWithPath: args[2])
    let db = base.appendingPathComponent("catalog.sqlite")
    let queryText =
      ProcessInfo.processInfo.environment["RAWMASTER_DISCOVERY_TEST_QUERY"] ?? "人用手喂驯鹿"
    let engine = try LibraryEngine.shared()
    _ = try write(db) { cn in
      try engine.transaction("install", on: cn, payload: LibraryEmpty(), as: CatalogJSON.self)
    }
    let actions = CatalogActions(
      database: db,
      writer: { cmd in
        try write(db) { cn in
          try engine.transaction("command", on: cn, payload: cmd, as: CatalogJSON.self)
        }
      })
    let srcDir = base.appendingPathComponent("Source")
    try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
    func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "''") + "'" }
    func payload(_ v: CatalogJSON) throws -> String {
      try quoted(String(decoding: JSONEncoder().encode(v), as: UTF8.self))
    }
    _ = try write(db) { c in
      try sql(
        c,
        "INSERT INTO projects VALUES('p',"
          + (try payload(.object(["id": .string("p"), "name": .string("Test")]))) + ")")
      try sql(
        c,
        "INSERT INTO sessions VALUES('s',"
          + (try payload(
            .object([
              "id": .string("s"), "projectID": .string("p"), "mode": .string("reference"),
              "sourcePath": .string(srcDir.path), "status": .string("completed"),
              "scanCompleted": .boolean(true),
            ]))) + ")")
      try sql(
        c,
        "INSERT INTO session_workflows VALUES('s',"
          + (try payload(
            .object([
              "sessionID": .string("s"), "projectID": .string("p"), "phase": .string("screening"),
              "importActive": .boolean(false),
            ]))) + ")")
      return .null
    }
    _ = try await actions.perform(
      "session.open", ["sessionID": .string("s"), "projectID": .string("p")])
    var items: [CatalogJSON] = []
    for (idx, path) in args.dropFirst(3).enumerated() {
      let original = URL(fileURLWithPath: path)
      let id = "input" + String(idx)
      let dest = srcDir.appendingPathComponent(id).appendingPathExtension(original.pathExtension)
      try FileManager.default.copyItem(at: original, to: dest)
      let raw = try Data(contentsOf: dest)
      let sha = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
      let a = CatalogJSON.object([
        "id": .string(id), "sessionID": .string("s"), "projectID": .string("p"),
        "filename": .string(dest.lastPathComponent), "sourcePath": .string(dest.path),
        "currentPath": .string(dest.path), "relativePath": .string(dest.lastPathComponent),
        "contentHash": .string(sha), "fileSize": .integer(Int64(raw.count)),
        "availability": .string("available"), "importState": .string("ready"),
      ])
      _ = try write(db) { c in
        try sql(
          c,
          "INSERT INTO assets(id,session_id,source_path,data) VALUES(" + quoted(id) + ",'s',"
            + quoted(dest.path) + "," + (try payload(a)) + ")")
        return .null
      }
      items.append(.object(["occurrenceID": .string(id), "disposition": .string("admitted")]))
    }
    _ = try write(db) { c in
      try engine.transaction("flushLegacy", on: c, payload: LibraryEmpty(), as: CatalogJSON.self)
    }
    _ = try await actions.perform(
      "session.seal", ["sessionID": .string("s"), "items": .array(items)])
    _ = try await actions.perform(
      "discover.configure", ["scene": .boolean(true), "faces": .boolean(true)])
    let queued = try await actions.perform("discover.sync")
    print("queued", queued["queued"] ?? .null)
    let runtime = LibraryDiscoveryWorker(
      runtime: pack.appendingPathComponent("runtime"), models: pack.appendingPathComponent("models")
    )
    let start = Date()
    let count = try await runtime.drain(actions: actions)
    let idxMs = Date().timeIntervalSince(start) * 1000
    let query = Date()
    let text = try await runtime.text(queryText)
    let grid = try await actions.read(
      "discovery", ["op": .string("search"), "model": text["model"]!, "vector": text["vector"]!])
    let ms = Date().timeIntervalSince(query) * 1000
    let job = try await actions.read("discovery", ["op": .string("jobs")])
    let face = try await actions.read("discovery", ["op": .string("clusters")])
    let excluded = try await actions.read(
      "discovery",
      [
        "op": .string("search"),
        "scope": .object(["query": .object(["minimumRating": .integer(5)])]),
        "model": text["model"]!, "vector": text["vector"]!,
      ])
    try FileManager.default.moveItem(at: srcDir, to: base.appendingPathComponent("Offline"))
    let first = grid["items"]?.arrayValue?.first?["workID"]?.stringValue ?? ""
    let descriptor = try await actions.read(
      "discovery", ["op": .string("preview"), "workID": .string(first)])
    let offline = try await runtime.preview(descriptor["input"]!, database: db)
    let metrics: [String: CatalogJSON] = [
      "offlineProxyLength": .integer(Int64(offline.count)),
      "sourceCount": .integer(Int64(args.count - 3)), "completed": .integer(Int64(count)),
      "queueAndProxyInferenceMs": .number(idxMs), "coldTextAndCatalogMs": .number(ms),
      "first": grid["items"]?.arrayValue?.first?["workID"] ?? .null,
      "eligible": grid["eligible"] ?? .null, "indexed": grid["indexed"] ?? .null,
      "hardExcluded": excluded["count"] ?? .null, "faceCount": face["observations"] ?? .null,
      "failures": job["failed"] ?? .null,
    ]
    try JSONEncoder().encode(metrics).write(to: base.appendingPathComponent("metrics.json"))
    print("completed", count)
    try check(count == (args.count - 3) * 2, "completion")
    try check(first.hasSuffix("input0"), "rank")
    try check(metrics["hardExcluded"] == .integer(0), "scope")
    await runtime.close()
  }
}
