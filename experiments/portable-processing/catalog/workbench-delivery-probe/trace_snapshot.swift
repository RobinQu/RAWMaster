import CSQLite
import Foundation
@testable import RAWMasterCore

struct TraceInput: Decodable {
    let assetID: String
    let contentSHA256: String
    let byteCount: Int64
}

final class SelectCounts {
    var asset = 0
    var admission = 0
}

guard CommandLine.arguments.count == 4 else {
    fatalError("expected a disposable fixture catalog, frozen input JSON and one of read, write, autocommit")
}
let store = try LibraryStore(databaseURL: URL(fileURLWithPath: CommandLine.arguments[1]))
let inputs = try JSONDecoder().decode([TraceInput].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let counts = SelectCounts()
let observer: @convention(c) (UInt32, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32 = { _, context, raw, _ in
    guard let raw, let context, let sql = sqlite3_sql(OpaquePointer(raw)) else { return 0 }
    let counts = Unmanaged<SelectCounts>.fromOpaque(context).takeUnretainedValue()
    let text = String(cString: sql)
    if text.contains("SELECT data FROM assets WHERE id=?") { counts.asset += 1 }
    if text.contains("printf('%!.26g',t.admitted_at)") { counts.admission += 1 }
    return 0
}
precondition(sqlite3_trace_v2(store.db, UInt32(SQLITE_TRACE_STMT), observer, Unmanaged.passUnretained(counts).toOpaque()) == SQLITE_OK)
func capture() throws -> [EditingSourceSnapshot] {
    try inputs.map { input in
        try store.editingSourceSnapshot(assetID: input.assetID, verifiedSHA256: input.contentSHA256,
                                        verifiedByteCount: input.byteCount)
    }
}
let mode = CommandLine.arguments[3]
let result: [EditingSourceSnapshot]
switch mode {
case "read":
    result = try store.withReadSnapshot { try capture() }
case "write":
    result = try store.locked {
        try store.exec("BEGIN IMMEDIATE")
        defer { try? store.exec("ROLLBACK") }
        precondition(sqlite3_txn_state(store.db, "main") == SQLITE_TXN_WRITE)
        return try capture()
    }
case "autocommit":
    precondition(sqlite3_get_autocommit(store.db) != 0)
    result = try capture()
default:
    fatalError("unrecognized transaction mode")
}
sqlite3_trace_v2(store.db, 0, nil, nil)
print("mode", mode, "sources", result.count, "assetSelects", counts.asset, "admissionSelects", counts.admission,
      "frozenSHA256", try EditingFingerprint.of(result))
