import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import SQLite3

@main struct WorkEditProbe {
  static func actions(_ db: URL) throws -> CatalogActions {
    let writer = try ProbeWriter(db)
    return CatalogActions(database: db) { try writer.transaction("command", $0) }
  }
  static func check(_ flag: Bool, _ message: String) throws {
    if !flag { throw ProbeError(message) }
  }
  static func fingerprint(_ image: CGImage) throws -> String {
    guard let provider = image.dataProvider, let bytes = provider.data as Data? else {
      throw ProbeError("no rendered pixels")
    }
    return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
  }
  struct ResultRow: Codable {
    let workID, versionID, parentVersionID, baseHash, pixelSHA: String
    let recipe: CatalogLocalRecipe, width: Int, height: Int
  }
  static func view(_ edit: CatalogLocalEdit) async throws -> (String, Int, Int) {
    let input = try await CatalogLocalEditing.image(for: edit, maxSize: 512)
    let bitmap = try CatalogLocalEditing.render(input, recipe: edit.recipe)
    return (try fingerprint(bitmap), bitmap.width, bitmap.height)
  }
  static func main() async {
    do {
      if CommandLine.arguments.dropFirst().first == "--original" {
        try await admittedOriginal()
      } else {
        try await run()
      }
    } catch {
      FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
      exit(1)
    }
  }
  static func admittedOriginal() async throws {
    let catalog = URL(fileURLWithPath: CommandLine.arguments[2])
    let source = URL(fileURLWithPath: CommandLine.arguments[3])
    let folder = catalog.deletingLastPathComponent()
    let writer = try ProbeWriter(catalog)
    _ = try writer.transaction("install")
    _ = try writer.transaction("flushLegacy")
    let sink = try actions(catalog)
    _ = try await sink.perform(
      "session.seal",
      [
        "sessionID": .string("s"),
        "items": .array([
          .object(["occurrenceID": .string("photo"), "disposition": .string("admitted")])
        ]),
      ])
    // The photograph is real and admitted. The migration descriptor models a missing historical preview.
    let master = "file:photo"
    let copy = "original-copy"
    _ = try await sink.perform(
      "org.saveWork",
      [
        "workID": .string(master),
        "appearance": .object(["origin": .string("lightroom"), "state": .string("missing")]),
      ])
    _ = try await sink.perform(
      "org.saveWork",
      [
        "workID": .string(copy), "kind": .string("virtual"),
        "masterWorkID": .string(master), "name": .string("Original copy"),
      ])
    let untouched = try await CatalogLocalEditing.open(master, actions: sink)
    let start = try await CatalogLocalEditing.open(copy, actions: sink)
    guard start.source?.kind == .original, let content = start.source?.contentID,
      start.sourceURL == source
    else {
      throw ProbeError("admitted native source unavailable")
    }
    let before = try await view(untouched)
    let recipe = CatalogLocalRecipe(
      exposureEV: 0.8, crop: .init(left: 0.09, top: 0.07, right: 0.89, bottom: 0.88))
    let version = try await CatalogLocalEditing.save(recipe, for: start, actions: sink)
    let edited = try await CatalogLocalEditing.open(copy, actions: sink)
    let pixels = try await view(edited)
    try check(
      edited.versionID == version && pixels.0 != before.0, "RAW recipe did not change pixels")
    let unchanged = try await CatalogLocalEditing.open(master, actions: sink)
    let checked = try await view(unchanged)
    try check(
      checked.0 == before.0 && unchanged.versionID == untouched.versionID,
      "RAW copy overwrote master")
    // Changing the private source between selection and decode must never substitute different pixels.
    let hidden = folder.appendingPathComponent("offline-source")
    try FileManager.default.moveItem(at: source, to: hidden)
    try Data([0, 1, 2]).write(to: source, options: .withoutOverwriting)
    var substituteRejected = false
    do { _ = try await CatalogLocalEditing.image(for: edited, maxSize: 64) } catch {
      substituteRejected = true
    }
    try FileManager.default.removeItem(at: source)
    try FileManager.default.moveItem(at: hidden, to: source)
    try check(substituteRejected, "source bytes substituted after open")
    let run = folder.deletingLastPathComponent()
    let pkg = run.appendingPathComponent("original-full-package")
    let dest = run.appendingPathComponent("original-restored")
    let made = try await sink.read(
      "package",
      ["op": .string("backup"), "mode": .string("full"), "destination": .string(pkg.path)])
    try check(made["state"] == .string("complete"), "full RAW package failed")
    let restored = try await sink.read(
      "package",
      ["op": .string("restore"), "package": .string(pkg.path), "destination": .string(dest.path)])
    guard let path = restored["libraryPath"]?.stringValue else {
      throw ProbeError("RAW library restore failed")
    }
    try FileManager.default.moveItem(at: source, to: hidden)
    let rebound = try await CatalogLocalEditing.open(
      copy, actions: try actions(URL(fileURLWithPath: path)))
    let returned = try await view(rebound)
    try check(
      rebound.versionID == version && rebound.recipe == recipe
        && rebound.source?.contentID == content
        && rebound.sourceURL?.path.hasPrefix(dest.path + "/") == true && returned.0 == pixels.0,
      "restored RAW version lost or changed its pixels")
    let summary: [String: Any] = [
      "actualAdmittedRAW": true, "migrationDescriptor": "controlledMissingLook",
      "originalAndCopyIndependent": true, "sourceSubstitutionRejected": true,
      "fullRestorePixelMatch": true,
      "externalSourceUnmounted": true, "restoredPreviewSize": [returned.1, returned.2],
    ]
    try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
      .write(
        to: folder.appendingPathComponent("original-evidence.json"), options: .withoutOverwriting)
  }
  static func run() async throws {
    let args = CommandLine.arguments
    let catalog = URL(fileURLWithPath: args[1])
    let scratch = URL(fileURLWithPath: args[2], isDirectory: true)
    let master = args[3]
    let copy = args[4]
    let sibling = "copy-" + UUID().uuidString
    let sink = try actions(catalog)
    let original = try await CatalogLocalEditing.open(master, actions: sink)
    let virtual = try await CatalogLocalEditing.open(copy, actions: sink)
    try check(
      original.belongsToLightroom && virtual.belongsToLightroom, "not Lightroom work versions")
    // Start a second virtual copy from the same master. Its later native version has a separate parent chain.
    _ = try await sink.perform(
      "org.saveWork",
      [
        "workID": .string(sibling), "kind": .string("virtual"), "masterWorkID": .string(master),
        "name": .string("Local validation copy"),
      ])
    let additional = try await CatalogLocalEditing.open(sibling, actions: sink)
    let start = [original, virtual, additional]
    let recipes = [
      CatalogLocalRecipe(
        exposureEV: -0.7, crop: .init(left: 0.05, top: 0.02, right: 0.98, bottom: 0.90)),
      CatalogLocalRecipe(
        exposureEV: 1.1, crop: .init(left: 0.18, top: 0.10, right: 0.81, bottom: 0.75)),
      CatalogLocalRecipe(exposureEV: 0.35, crop: .init(left: 0.10, top: 0, right: 0.95, bottom: 1)),
    ]
    var saved = [ResultRow]()
    let untouched = try await view(original)
    for i in [1, 2, 0] {
      let initial = start[i]
      guard let parent = initial.versionID, let base = initial.source, let u = initial.sourceURL
      else { throw ProbeError("source is unavailable") }
      let sourcePreview = LibraryHistogramSource(
        kind: .proxy, url: u, sha256: base.sha256, versionID: parent)
      let sample = try await LibraryInspectionReader.workHistogram(
        sourcePreview, workID: initial.workID)
      try check(
        sample["scope"] == .string("workVersion") && sample["workID"] == .string(initial.workID),
        "wrong offline histogram binding")
      let newID = try await CatalogLocalEditing.save(recipes[i], for: initial, actions: sink)
      let opened = try await CatalogLocalEditing.open(initial.workID, actions: try actions(catalog))
      let pixels = try await view(opened)
      try check(
        opened.hasLocalVersion && opened.versionID == newID && opened.recipe == recipes[i],
        "reopened wrong recipe or version")
      let org = try await sink.read(
        "organization", ["view": .string("work"), "workID": .string(initial.workID)])
      let v = org["versions"]?.arrayValue?.first { $0["versionID"] == .string(newID) }
      try check(v?["parentVersionID"] == .string(parent), "foreign editing parent")
      if i != 0 {
        let m = try await CatalogLocalEditing.open(master, actions: sink)
        let compare = try await view(m)
        try check(
          m.versionID == original.versionID && compare.0 == untouched.0,
          "editing a copy overwrote its master")
      }
      guard let rendered = try await CatalogLocalPreviewCache.shared.sample(for: opened) else {
        throw ProbeError("no per-version render for inspection")
      }
      let hist = try await LibraryInspectionReader.workHistogram(rendered, workID: opened.workID)
      try check(
        hist["kind"] == .string("render") && hist["versionID"] == .string(newID),
        "wrong active-version RGB histogram")
      saved.append(
        ResultRow(
          workID: initial.workID, versionID: newID, parentVersionID: parent, baseHash: base.sha256,
          pixelSHA: pixels.0, recipe: opened.recipe, width: pixels.1, height: pixels.2))
    }
    // Copying a master *after* its first native edit inherits both pixels and the
    // verified Lightroom starting point, then diverges with its own next save.
    let lateID = "copy-" + UUID().uuidString
    _ = try await sink.perform(
      "org.saveWork",
      [
        "workID": .string(lateID), "kind": .string("virtual"), "masterWorkID": .string(master),
        "name": .string("Inherited local edit"),
      ])
    let late = try await CatalogLocalEditing.open(lateID, actions: sink)
    let masterNow = try await CatalogLocalEditing.open(master, actions: sink)
    let inheritedPixels = try await view(late)
    let masterPixels = try await view(masterNow)
    try check(
      late.hasLocalVersion && late.recipe == masterNow.recipe
        && inheritedPixels.0 == masterPixels.0, "new virtual lost existing native work appearance")
    let fourth = CatalogLocalRecipe(
      exposureEV: -1.65, crop: .init(left: 0.3, top: 0.17, right: 1, bottom: 1))
    let newVersion = try await CatalogLocalEditing.save(fourth, for: late, actions: sink)
    let changed = try await CatalogLocalEditing.open(lateID, actions: sink)
    let changedPixels = try await view(changed)
    let masterAfterCopy = try await CatalogLocalEditing.open(master, actions: sink)
    let sourcePixels = try await view(masterAfterCopy)
    try check(
      sourcePixels.0 == masterPixels.0 && changedPixels.0 != masterPixels.0,
      "newly copied work leaked edits to master")
    guard let lateBase = changed.source, let lateParent = late.versionID else {
      throw ProbeError("missing inherited source or parent")
    }
    saved.append(
      ResultRow(
        workID: lateID, versionID: newVersion, parentVersionID: lateParent,
        baseHash: lateBase.sha256,
        pixelSHA: changedPixels.0, recipe: changed.recipe, width: changedPixels.1,
        height: changedPixels.2))
    let foreign = "foreign-" + UUID().uuidString
    var claimed = try CatalogJSON.encoding(lateBase).decoded([String: CatalogJSON].self)
    claimed["sourceWorkID"] = .string(copy)
    _ = try await sink.perform(
      "org.saveWork",
      [
        "workID": .string(foreign), "kind": .string("virtual"), "masterWorkID": .string(master),
        "name": .string("Foreign descriptor"),
        "appearance": .object([
          "origin": .string("rawmasterLocalDevelop"), "schemaVersion": .integer(1),
          "recipe": try .encoding(fourth), "source": .object(claimed),
        ]),
      ])
    let forged = try await CatalogLocalEditing.open(foreign, actions: sink)
    try check(forged.sourceURL == nil, "foreign work bound using a shared physical JPEG")
    var conflict = false
    do {
      _ = try await CatalogLocalEditing.save(.init(exposureEV: 3), for: virtual, actions: sink)
    } catch { conflict = true }
    try check(conflict, "stale copy replaced an existing version")
    let pkg = scratch.appendingPathComponent("package")
    let dest = scratch.appendingPathComponent("restored")
    let b = try await sink.read(
      "package",
      ["op": .string("backup"), "mode": .string("catalog"), "destination": .string(pkg.path)])
    try check(b["state"] == .string("complete"), "catalog package failed")
    let r = try await sink.read(
      "package",
      ["op": .string("restore"), "package": .string(pkg.path), "destination": .string(dest.path)])
    guard let db = r["libraryPath"]?.stringValue else { throw ProbeError("cannot restore catalog") }
    // Remove the previous library's resource root from its known path before opening the restored one.
    let old = catalog.deletingLastPathComponent().appendingPathComponent("LibraryResources")
    let hidden = old.deletingLastPathComponent().appendingPathComponent("resources-offline")
    try FileManager.default.moveItem(at: old, to: hidden)
    let restored = try actions(URL(fileURLWithPath: db))
    for row in saved {
      let opened = try await CatalogLocalEditing.open(row.workID, actions: restored)
      let re = try await view(opened)
      try check(
        opened.versionID == row.versionID && opened.recipe == row.recipe
          && opened.source?.sha256 == row.baseHash, "lost restored binding")
      try check(
        opened.sourceURL?.path.hasPrefix(dest.path + "/LibraryResources/") == true
          && re.0 == row.pixelSHA && re.1 == row.width && re.2 == row.height,
        "wrong restored media or pixels")
    }
    let report: [String: Any] = [
      "editedWorks": saved.count, "independentVersions": Set(saved.map(\.versionID)).count,
      "distinctRenderedHashes": Set(saved.map(\.pixelSHA)).count,
      "offlinePreviewHistograms": 3, "versionedRenderHistograms": 3, "staleSaveRejected": conflict,
      "restoredPixelHashesMatched": saved.count,
      "sourceResourceRootUnmounted": true, "copiedAlreadyEditedMaster": true,
      "foreignWorkResourceRejected": true,
      "renderedSizes": saved.map { [$0.width, $0.height] },
    ]
    let data = try JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(
      to: scratch.appendingPathComponent("evidence.json"), options: .withoutOverwriting)
    print(String(decoding: data, as: UTF8.self))
  }
}
