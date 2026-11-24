import Foundation
import RAWMasterLibrary

extension LibraryStore {
  package func catalogLibraryIdentity() throws -> String {
    guard let id = try rows("SELECT value FROM lc_meta WHERE key='libraryID'").first?.first, !id.isEmpty else {
      throw LibraryError.invalid("资料库缺少标识。")
    }
    return id
  }

  /// Fence a reversible, catalog-owned stage while retaining the lease until final delivery.
  public func withCatalogTaskFence<T>(_ lease: CatalogTaskLease, _ operation: () throws -> T) throws -> T {
    guard databaseURL == lease.database.standardizedFileURL.resolvingSymlinksInPath() else {
      throw LibraryError.invalid("任务属于另一资料库。")
    }
    return try transaction {
      let fields = ["key": CatalogJSON.string(lease.key), "token": .string(lease.token)]
      _ = try catalogTransaction("checkTaskLease", fields)
      let value = try operation()
      _ = try catalogTransaction("checkTaskLease", fields)
      return value
    }
  }

  /// Reconcile a verified, previously committed domain result even if its process died before its queue ACK.
  /// The closure compares the stored frozen descriptor to the actual domain receipt and returns nil for no match.
  public func completeVerifiedCatalogTask<T>(key: String, _ verify: (CatalogJSON) throws -> (T, String)?) throws -> T? {
    try transaction {
      let row = try catalogTransaction("taskForReceipt", ["key": CatalogJSON.string(key)])
      guard let payload = row["payload"], let (value, receipt) = try verify(payload) else { return nil }
      _ = try catalogTransaction("completeVerifiedTask", ["key": CatalogJSON.string(key), "receipt": .string(receipt)])
      return value
    }
  }

  /// Publish a catalog-owned result and its stable domain receipt in the same serialized transaction.
  /// The caller stages files and performs all expensive processing before entering this closure.
  public func publishCatalogTask<T>(_ lease: CatalogTaskLease, _ publish: () throws -> (T, String)) throws -> T {
    guard databaseURL == lease.database.standardizedFileURL.resolvingSymlinksInPath() else {
      throw LibraryError.invalid("任务属于另一资料库。")
    }
    return try transaction {
      var fields = ["key": CatalogJSON.string(lease.key), "token": .string(lease.token)]
      _ = try catalogTransaction("checkTaskLease", fields)
      let (value, receipt) = try publish()
      fields["receipt"] = .string(receipt)
      _ = try catalogTransaction("finishTaskReceipt", fields)
      return value
    }
  }
}
