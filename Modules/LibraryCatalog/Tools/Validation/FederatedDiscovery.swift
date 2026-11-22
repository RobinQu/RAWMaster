import CryptoKit
import Foundation
import SQLite3

/// Two independently admitted, private v8 libraries with one deliberately shared display name/work ID.
/// Usage: FederatedDiscovery <first.sqlite> <second.sqlite> <new-output-directory> <installed-ml-root>
private actor QueryGate {
  private var started = false
  private var open = false
  private var arrival: CheckedContinuation<Void, Never>?
  private var release: CheckedContinuation<Void, Never>?

  func hold() async {
    started = true
    arrival?.resume()
    arrival = nil
    if !open { await withCheckedContinuation { release = $0 } }
  }
  func waitUntilStarted() async {
    if !started { await withCheckedContinuation { arrival = $0 } }
  }
  func resume() {
    open = true
    release?.resume()
    release = nil
  }
}

@main
struct FederatedDiscovery {
  private static func check(_ verdict: Bool, _ message: String) throws {
    guard verdict else { throw LibraryEngineError(message) }
  }
  private static func sha(_ url: URL) throws -> Data {
    Data(SHA256.hash(data: try Data(contentsOf: url)))
  }
  private static func generation(_ report: CatalogJSON) -> CatalogJSON {
    report["watermark"] ?? .null
  }
  /// Only the temporary copy changes. Inputs are always opened read-only.
  private static func copyWithFacesDisabled(from original: URL, to copy: URL) throws {
    var source: OpaquePointer?
    guard sqlite3_open_v2(original.path, &source, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
      let source
    else {
      throw LibraryEngineError("Cannot open input fixture")
    }
    defer { sqlite3_close(source) }
    var dest: OpaquePointer?
    guard sqlite3_open(copy.path, &dest) == SQLITE_OK, let dest else {
      throw LibraryEngineError("Cannot create fixture")
    }
    defer { sqlite3_close(dest) }
    guard let backup = sqlite3_backup_init(dest, "main", source, "main") else {
      throw LibraryEngineError("Cannot begin fixture snapshot")
    }
    let step = sqlite3_backup_step(backup, -1)
    let finish = sqlite3_backup_finish(backup)
    try check(step == SQLITE_DONE && finish == SQLITE_OK, "Fixture snapshot failed")
    try check(
      sqlite3_exec(dest, "PRAGMA foreign_keys=ON;BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
      "Fixture transaction")
    do {
      _ = try LibraryEngine.shared().transaction(
        "command", on: dest,
        payload: CatalogJSON.object([
          "action": .string("discover.configure"), "version": .integer(1),
          "commandID": .string(UUID().uuidString), "faces": .boolean(false),
        ]), as: CatalogJSON.self)
      try check(sqlite3_exec(dest, "COMMIT", nil, nil, nil) == SQLITE_OK, "Commit fixture policy")
    } catch {
      sqlite3_exec(dest, "ROLLBACK", nil, nil, nil)
      throw error
    }
  }
  @MainActor static func main() async throws {
    let inputs = Array(CommandLine.arguments.dropFirst()).map { URL(fileURLWithPath: $0) }
    guard inputs.count == 4 else { throw LibraryEngineError("Expected four paths") }
    let (first, second, output, runtime) = (inputs[0], inputs[1], inputs[2], inputs[3])
    let files = FileManager.default
    try check(!files.fileExists(atPath: output.path), "Use an empty, new output directory")
    try files.createDirectory(at: output, withIntermediateDirectories: true)
    let package = output.appendingPathComponent("Frozen.rawmasterlibrary")
    let engine = try LibraryEngine.shared()
    let firstBefore = try sha(first)
    let secondBefore = try sha(second)
    let sourceFolder = output.appendingPathComponent("PrivateSource")
    try files.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
    let policySource = sourceFolder.appendingPathComponent("library.sqlite")
    try copyWithFacesDisabled(from: second, to: policySource)
    _ = try engine.request(
      "package", at: policySource,
      payload: CatalogJSON.object([
        "op": .string("backup"), "mode": .string("catalog"), "destination": .string(package.path),
      ]), as: CatalogJSON.self)
    let a = try LibraryDiscoveryFederation.target(at: first, isCurrent: true)
    let saved = try LibraryDiscoveryFederation.target(at: package)
    let b = try LibraryDiscoveryFederation.refresh(
      JSONDecoder().decode(LibraryDiscoveryTarget.self, from: JSONEncoder().encode(saved)))
    try check(
      a.libraryID != b.libraryID && saved.id == b.id && b.bookmark != nil && b.current == nil
        && b.generation != nil, "Independent library and package bookmark")
    let packedDB = package.appendingPathComponent("library.sqlite")
    let packedBefore = try sha(packedDB)
    let ap = try LibraryDiscoveryFederation.read(a)
    let bp = try LibraryDiscoveryFederation.read(b)
    try check(
      ap["count"] == .integer(4) && bp["count"] == .integer(3), "Real admitted asset counts")
    try check(
      ap["libraryID"] == .string(a.libraryID) && bp["libraryID"] == .string(b.libraryID),
      "Source identity")
    try check(generation(ap) != .null && generation(bp) != .null, "Per-source watermark")
    let aNamed = try LibraryDiscoveryFederation.read(a, metadata: "input0")
    let bNamed = try LibraryDiscoveryFederation.read(b, metadata: "input0")
    try check(
      aNamed["count"] == .integer(1) && bNamed["count"] == .integer(1), "Exact metadata hard filter"
    )
    let firstHit = aNamed["items"]?.arrayValue?.first
    let secondHit = bNamed["items"]?.arrayValue?.first
    try check(
      firstHit?["name"] == secondHit?["name"] && firstHit?["workID"] == secondHit?["workID"]
        && firstHit?["inputVersion"]?.stringValue != nil
        && secondHit?["inputVersion"]?.stringValue != nil,
      "Identical work and name retain composite identity and version")
    let excluded = try LibraryDiscoveryFederation.read(a, metadata: "input0", minimumRating: 5)
    try check(excluded["count"] == .integer(0), "Common metadata rating must restrict search")
    let project = LibraryDiscoveryLocalFilter(
      sourceID: a.id, scope: ["projectID": .string("unselected-project")])
    let none = try LibraryDiscoveryFederation.read(a, local: project)
    try check(
      none["count"] == .integer(0) && bp["count"] == .integer(3),
      "Local project scope must not propagate to another source")
    var foreignRejected = false
    do {
      _ = try LibraryDiscoveryFederation.read(
        b, local: .init(sourceID: a.id, personID: "same-person-id"))
    } catch { foreignRejected = error.localizedDescription.contains("另一份资料库") }
    try check(foreignRejected, "Foreign person must never be interpreted against another source")
    var ownConsentRejected = false
    do {
      _ = try LibraryDiscoveryFederation.read(
        b, local: .init(sourceID: b.id, personID: "same-person-id"))
    } catch { ownConsentRejected = error.localizedDescription.contains("未开启人物检索") }
    try check(
      ownConsentRejected, "Another library's enabled face setting must not authorize this archive")
    let options = try LibraryDiscoveryFederation.choices(b)
    try check(options["people"] == .array([]), "No people exposed from disabled library")
    let worker = LibraryDiscoveryWorker(
      runtime: runtime.appendingPathComponent("runtime/bin/python3.12"),
      models: runtime.appendingPathComponent("models"))
    let vector = try await worker.text("人用手喂驯鹿")
    let semanticA = try LibraryDiscoveryFederation.read(a, visual: vector)
    let semanticB = try LibraryDiscoveryFederation.read(b, visual: vector)
    try check(
      semanticA["indexed"] == .integer(4) && semanticA["missing"] == .integer(0),
      "Indexed live source")
    try check(
      semanticB["indexed"] == .integer(0) && semanticB["missing"] == .integer(3),
      "Backup missing rebuildable features")
    try check(
      !files.fileExists(atPath: package.appendingPathComponent("LibraryIndexes").path),
      "Read-only archive must never acquire a feature store")
    let gate = QueryGate()
    let batch = LibraryDiscoverySearchBatch()
    let late = Task {
      await batch.search([a, b]) { source in
        if source.id == b.id { await gate.hold() }
        return try LibraryDiscoveryFederation.read(source, metadata: "input0")
      }
    }
    await gate.waitUntilStarted()
    await batch.search([a]) { try LibraryDiscoveryFederation.read($0, metadata: "input0") }
    await gate.resume()
    await late.value
    try check(
      batch.sections.map(\.id) == [a.id] && batch.sections[0].result?["count"] == .integer(1),
      "Late reply from unchecked source must be discarded")
    batch.invalidate()
    try check(batch.sections.isEmpty, "Cancelled selections must clear old hits")
    // Place the selected package database temporarily offline while keeping the bookmark location.
    let offline = output.appendingPathComponent("reversibly-offline.sqlite")
    try files.moveItem(at: packedDB, to: offline)
    await batch.search([a, b]) { try LibraryDiscoveryFederation.read($0) }
    try files.moveItem(at: offline, to: packedDB)
    try check(
      batch.sections.count == 2 && batch.sections[0].result?["count"] == .integer(4)
        && batch.sections[1].error != nil, "Failure stays attached to one source")
    // Same length and same identity/generation. A changed file stamp must trigger SHA verification.
    let savedBytes = try Data(contentsOf: packedDB)
    var tampered = savedBytes
    tampered[tampered.count - 1] ^= 1
    try tampered.write(to: packedDB, options: .atomic)
    var rejectedTamper = false
    do { _ = try LibraryDiscoveryFederation.read(b) } catch {
      rejectedTamper = error.localizedDescription.contains("摘要不匹配")
    }
    try savedBytes.write(to: packedDB, options: .atomic)
    try check(rejectedTamper, "Same-size changed package rejected")
    let reopened = try LibraryDiscoveryFederation.read(b)
    try check(reopened["count"] == .integer(3), "Same generation can reconnect")
    try check(
      try sha(packedDB) == packedBefore && sha(first) == firstBefore && sha(second) == secondBefore,
      "Library digests changed")
    let result = CatalogJSON.object([
      "schemaVersion": .integer(1),
      "run": .string("macOS Apple Silicon, Swift 6, Rust v8 read API"),
      "sourceKinds": .array([
        .string("checked live v8 catalog"), .string("checked immutable catalog-only package"),
      ]),
      "eligibleBySource": .array([ap["eligible"]!, bp["eligible"]!]),
      "semanticIndexedBySource": .array([semanticA["indexed"]!, semanticB["indexed"]!]),
      "semanticMissingBySource": .array([semanticA["missing"]!, semanticB["missing"]!]),
      "sameNameAndWorkIDHitsBySource": .array([aNamed["count"]!, bNamed["count"]!]),
      "perSourceIDVersionAndWatermark": .boolean(true), "ownRatingRestricted": .boolean(true),
      "foreignPersonScopeRejected": .boolean(foreignRejected),
      "ownConsentRequired": .boolean(ownConsentRejected),
      "sameSizePackageTamperingRejected": .boolean(rejectedTamper),
      "currentProjectScopePreserved": .boolean(true),
      "lateDeselectedSourceDiscarded": .boolean(true),
      "oneOfflineSourceIsolatedAndReconnected": .boolean(true),
      "securityScopedReadOnlyBookmarkRoundTrip": .boolean(true),
      "packageCreatedCacheDuringRead": .boolean(false), "authorityDigestsUnchanged": .boolean(true),
    ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(result).write(to: output.appendingPathComponent("metrics.json"))
    print("Two sources passed scoped read, identity, cancellation, coverage and failure checks.")
  }
}
