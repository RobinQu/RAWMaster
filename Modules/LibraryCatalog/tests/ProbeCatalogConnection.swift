import Foundation
import SQLite3

#if canImport(RAWMasterLibrary)
  import RAWMasterLibrary
#endif

struct ProbeError: Error, LocalizedError {
  var errorDescription: String?
  init(_ value: String) { errorDescription = value }
}
final class ProbeWriter: @unchecked Sendable {
  let db: OpaquePointer
  let lock = NSLock()
  init(_ url: URL) throws {
    var handle: OpaquePointer?
    guard
      sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK, let handle
    else {
      throw ProbeError("Cannot open private reference database")
    }
    // The production host reads its version on the writable connection at startup.
    // This also opens the WAL sidecars of a newly restored SQLite snapshot before standalone readers start.
    guard sqlite3_exec(handle, "PRAGMA user_version", nil, nil, nil) == SQLITE_OK else {
      let reason = String(cString: sqlite3_errmsg(handle))
      sqlite3_close(handle)
      throw ProbeError("Cannot read private reference database version: " + reason)
    }
    db = handle
  }
  deinit { sqlite3_close(db) }
  func transaction(_ op: String, _ body: CatalogJSON = .object([:])) throws -> CatalogJSON {
    lock.lock()
    defer { lock.unlock() }
    guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
      throw ProbeError("Cannot begin test write")
    }
    do {
      let result = try LibraryEngine.shared().transaction(
        op, on: db, payload: body, as: CatalogJSON.self)
      if op == "install" {
        guard sqlite3_exec(db, "PRAGMA user_version=8", nil, nil, nil) == SQLITE_OK else {
          throw ProbeError("Cannot advance private host schema")
        }
      }
      guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
        throw ProbeError("Cannot commit test write")
      }
      return result
    } catch {
      sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
      throw error
    }
  }
}
