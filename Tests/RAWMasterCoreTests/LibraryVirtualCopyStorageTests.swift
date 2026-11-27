import AppKit
import Foundation
import RAWMasterLibrary
import XCTest
@testable import RAWMasterCore

extension EditingTests {
  func testVirtualRenditionIdentityNameConflictsRemovalAndRepeatedCreation() throws {
    let base = try work()
    let color = DevelopmentRecipe(exposureEV: 0.75)
    _ = try store.saveLiveDevelopmentState(workID: base.id, recipe: color, parentVersionID: base.originalVersionID, expectedRevision: 0)
    let createID = UUID().uuidString
    let copy = try store.createVirtualCopy(of: asset, name: "  Study  ", id: createID)
    let rendition = copy.projecting(asset)
    XCTAssertThrowsError(try store.createVirtualCopy(of: asset, name: "Collision", id: asset.id))
    XCTAssertEqual(copy.name, "Study")
    XCTAssertEqual(try store.createVirtualCopy(of: asset, name: "  Study  ", id: createID), copy)
    XCTAssertThrowsError(try store.createVirtualCopy(of: asset, name: "different", id: createID))
    XCTAssertThrowsError(try store.createVirtualCopy(of: asset, name: "study"))
    XCTAssertEqual(try store.loadAssets().count, 1)
    XCTAssertEqual(try store.editingWorks(for: asset).map(\.id), [base.id])
    let own = try XCTUnwrap(store.editingWorks(for: rendition).first)
    XCTAssertEqual(own.liveRecipe, color)
    XCTAssertEqual(own.source.assetID, asset.id)
    XCTAssertNotEqual(own.originalVersionID, base.originalVersionID)
    _ = try store.saveLiveDevelopmentState(workID: own.id, recipe: .init(exposureEV: -1), parentVersionID: own.originalVersionID, expectedRevision: 0)
    let fork = try store.createVirtualCopy(of: rendition, name: "Second")
    XCTAssertEqual(try store.photoWork(id: fork.id).liveRecipe?.exposureEV, -1)
    XCTAssertEqual(try store.photoWork(id: base.id).liveRecipe, color)
    let reopened = try LibraryStore(databaseURL: database)
    let renamed = try reopened.updateVirtualCopy(copy, name: "Dark")
    XCTAssertThrowsError(try store.updateVirtualCopy(copy, removed: true))
    let hidden = try store.updateVirtualCopy(renamed, removed: true)
    XCTAssertEqual(try reopened.virtualCopies().map(\.id), [fork.id])
    XCTAssertThrowsError(try reopened.editingWorks(for: rendition))
    _ = try reopened.updateVirtualCopy(hidden, removed: false)
    XCTAssertEqual(try store.editingWorks(for: rendition).first?.id, own.id)
    XCTAssertEqual(try reopened.virtualCopies().map(\.name), ["Dark", "Second"])
    XCTAssertEqual(try reopened.renditionPreviewRevisions().count, 3)
    try FileManager.default.removeItem(at: sourceURL)
    XCTAssertEqual(try store.createVirtualCopy(of: asset, name: "  Study  ", id: createID).id, copy.id)
  }

  func testArchivedCopiesShareVerifiedBytesAcrossBackupAndRestore() throws {
    let master = try work(), (file, artifact) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let receipt = try archive.publish(fileURL: file, version: version(master, artifact: artifact, kind: .external))
    _ = try store.commitArchivePublication(receipt)
    _ = try store.adoptEditingVersion(workID: master.id, versionID: receipt.version.id, expectedRevision: 0)
    let copy = try store.createVirtualCopy(of: asset, name: "Archive")
    let nested = try store.createVirtualCopy(of: copy.projecting(asset), name: "Archive 2")
    let backup = root.appendingPathComponent("Backup")
    let manifest = try store.backupEditingLibrary(to: backup)
    XCTAssertEqual(manifest.files.count, 2)
    let restored = try LibraryStore.restoreEditingLibrary(from: backup, databaseURL: root.appendingPathComponent("Restored/library.sqlite"),
                                                          archiveRoot: root.appendingPathComponent("Restored/Archive"))
    for entry in [copy,nested] {
      let work = try restored.photoWork(id: entry.id)
      let alias = try restored.editingVersion(id: work.adoptedVersionID)
      XCTAssertEqual(alias.configuration["virtualCopyArchiveSource"], receipt.version.id)
      XCTAssertEqual(alias.artifact, receipt.version.artifact)
      let path = try restored.editingArchive().artifactURL(XCTUnwrap(alias.artifact))
      XCTAssertEqual(try FileSafety.hash(path), artifact.sha256)
    }
    XCTAssertEqual(try restored.renditionPreviewRevisions().count, 3)
  }

  func testFullLibraryPackageRestoresArchivePixelsAndScopedSnapshotsForNestedCopies() async throws {
    let master = try work()
    let file = root.appendingPathComponent("red-green.png")
    // Two 8-bit RGB pixels, red followed by green.
    let pixels = try XCTUnwrap(Data(base64Encoded:
      "iVBORw0KGgoAAAANSUhEUgAAAAIAAAABCAIAAAB7QOjdAAAAD0lEQVR4nGP4z8DA8J8BAAf/Af8Bf4mnAAAAAElFTkSuQmCC"))
    try pixels.write(to: file)
    let artifact = RenderArtifact(sha256: try FileSafety.hash(file), byteCount: Int64(pixels.count),
                                  pixelWidth: 2, pixelHeight: 1, encoding: "png", bitDepth: 8, colorSpace: "sRGB")
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    var candidate = version(master, artifact: artifact, kind: .development)
    let preset = DevelopmentPresetRecord(id: "study", name: "曝光", group: "本地", kind: .user, patch: .init())
    let adoption = try DevelopmentPresetAdoption(record: preset, sourceID: asset.id, amount: 1,
      baseline: .init(), result: candidate.recipe, masks: nil)
    candidate.presetAdoptions = [adoption]
    let publication = try archive.publish(fileURL: file, version: candidate)
    _ = try store.commitArchivePublication(publication)
    _ = try store.adoptEditingVersion(workID: master.id, versionID: publication.version.id, expectedRevision: 0)
    let copy = try store.createVirtualCopy(of: asset, name: "归档副本")
    let nested = try store.createVirtualCopy(of: copy.projecting(asset), name: "第二级")
    let initialCopy = try store.photoWork(id: copy.id)
    XCTAssertEqual(initialCopy.liveParentVersionID, initialCopy.adoptedVersionID)
    XCTAssertEqual(initialCopy.liveRecipe, candidate.recipe)
    XCTAssertEqual(initialCopy.livePresetAdoptions, [adoption])
    let changed = DevelopmentRecipe(exposureEV: -1.5)
    _ = try store.saveLiveDevelopmentState(workID: copy.id, recipe: changed, parentVersionID: initialCopy.adoptedVersionID,
                                            expectedRevision: 0)
    XCTAssertEqual(try store.photoWork(id: master.id).adoptedVersionID, publication.version.id)

    var expected: [DevelopmentSnapshotScope: [DevelopmentSnapshot]] = [:]
    for (index, id) in [master.id, copy.id, nested.id].enumerated() {
      let work = try store.photoWork(id: id)
      let scope = DevelopmentSnapshotScope(workID: id, parentVersionID: work.originalVersionID, appearance: .compatibility)
      expected[scope] = try store.updateDevelopmentSnapshots(in: scope,
        .create(id: UUID(), name: "分支 \(index)", createdAt: .now, recipe: .init(exposureEV: Double(index)), adoptions: nil))
    }

    let actions = store.catalogActions
    let package = root.appendingPathComponent("备份.rawmasterlibrary")
    let backup = try await actions.read("package", ["op": .string("backup"), "mode": .string("full"),
                                                    "destination": .string(package.path)])
    XCTAssertEqual(backup["coveredOriginalFiles"], .integer(1))
    XCTAssertEqual(backup["resourceReferences"], .integer(2))
    XCTAssertEqual(backup["copiedObjects"], .integer(3))
    let digest = try XCTUnwrap(backup["manifestSHA256"]?.stringValue)

    let fm = FileManager.default
    try fm.removeItem(at: sourceURL)
    try fm.removeItem(at: archive.root)
    try fm.removeItem(at: file)
    let target = root.appendingPathComponent("RestoredPackage")
    let receipt = try await actions.read("package", ["op": .string("restore"), "package": .string(package.path),
      "expectedManifestSHA256": .string(digest), "destination": .string(target.path)])
    XCTAssertEqual(receipt["restoredFiles"], .integer(1))
    XCTAssertEqual(receipt["restoredResources"], .integer(2))
    let databasePath = try XCTUnwrap(receipt["libraryPath"]?.stringValue)
    let reopened = try LibraryStore(databaseURL: URL(fileURLWithPath: databasePath))
    let restoredAsset = try XCTUnwrap(reopened.loadAssets().first)
    XCTAssertTrue(FileSafety.contains(target, restoredAsset.resolvedURL))
    XCTAssertEqual(try FileSafety.hash(restoredAsset.resolvedURL), source.contentSHA256)
    XCTAssertEqual(try reopened.virtualCopies(projectID: asset.projectID), [copy, nested])

    let restoredArchive = try reopened.editingArchive()
    try restoredArchive.validate(publication)
    var paths = Set<URL>()
    for id in [master.id, copy.id, nested.id] {
      let work = try reopened.photoWork(id: id)
      let adopted = try reopened.editingVersion(id: work.adoptedVersionID)
      let owner = try reopened.archivedOwner(of: adopted)
      XCTAssertEqual(owner, publication.version)
      XCTAssertEqual(adopted.source.assetID, restoredAsset.id)
      XCTAssertEqual(adopted.kind, .development)
      XCTAssertEqual(adopted.recipe, candidate.recipe)
      XCTAssertEqual(adopted.presetAdoptions, [adoption])
      if id == copy.id { XCTAssertEqual(work.liveRecipe, changed) }
      if id == nested.id { XCTAssertEqual(work.liveRecipe, candidate.recipe) }
      paths.insert(try restoredArchive.artifactURL(XCTUnwrap(adopted.artifact)))
    }
    XCTAssertEqual(paths.count, 1)
    let path = try XCTUnwrap(paths.first)
    XCTAssertTrue(FileSafety.contains(target, path))
    XCTAssertEqual(try FileSafety.hash(path), artifact.sha256)
    let decoded = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: path)))
    XCTAssertEqual(decoded.pixelsWide, 2)
    XCTAssertEqual(decoded.pixelsHigh, 1)
    var sample = Array(repeating: 0, count: decoded.samplesPerPixel)
    decoded.getPixel(&sample, atX: 0, y: 0)
    XCTAssertEqual(Array(sample.prefix(3)), [255, 0, 0])
    decoded.getPixel(&sample, atX: 1, y: 0)
    XCTAssertEqual(Array(sample.prefix(3)), [0, 255, 0])
    for (scope, snapshots) in expected {
      XCTAssertEqual(try reopened.developmentSnapshots(in: scope), snapshots)
    }
  }

  func testBackupsRejectVirtualArchiveReferenceOwnedByAnotherPhoto() async throws {
    let master = try work(), (file, artifact) = try renderedFile()
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let owner = try archive.publish(fileURL: file, version: version(master, artifact: artifact, kind: .external))
    _ = try store.commitArchivePublication(owner)
    let otherURL = sourceURL.deletingLastPathComponent().appendingPathComponent("other.RAW")
    try Data("second camera original".utf8).write(to: otherURL)
    _ = try store.admitLightroomOriginal(otherURL, projectID: asset.projectID)
    let other = try XCTUnwrap(store.loadAssets().first { $0.id != asset.id })
    let copy = try store.createVirtualCopy(of: other, name: "副本")
    let work = try store.photoWork(id: copy.id)
    let wrong = EditingVersion(workID: work.id, parentVersionID: work.originalVersionID, kind: .external,
      source: owner.version.source, artifact: owner.version.artifact, configuration: ["virtualCopyArchiveSource": owner.version.id])
    // Simulate a damaged catalog row that points at a genuine publication of a different photo.
    try store.insertVersion(wrong)
    try await assertArchiveRejected(wrong.id, name: "cross-photo")
  }

  func testArchivedDevelopmentCopyKeepsOtherAppearanceAndRejectsMismatchedRecipeAndPreset() async throws {
    let raw = sourceURL.deletingLastPathComponent().appendingPathComponent("alternate.ARW")
    try Data("source for stored HDR graph".utf8).write(to: raw)
    _ = try store.admitLightroomOriginal(raw, projectID: asset.projectID)
    let physical = try XCTUnwrap(store.loadAssets().first { $0.id != asset.id })
    let work = try store.createPhotoWork(source: store.captureEditingSourceSnapshot(assetID: physical.id))
    let (file, artifact) = try renderedFile()
    let candidate = version(work, artifact: artifact)
    let hdr = try DevelopmentRecipe(sceneGraph: .initialAppearance(from: candidate.recipe))
    let alternate = DevelopmentAppearanceAlternate(recipe: candidate.recipe)
    _ = try store.saveLiveDevelopmentState(workID: work.id, recipe: hdr, parentVersionID: work.originalVersionID,
      expectedRevision: 0, alternateAppearance: alternate)
    let archive = try store.configureEditingArchive(root: root.appendingPathComponent("Archive"))
    let stored = try store.commitArchivePublication(archive.publish(fileURL: file, version: candidate))
    _ = try store.adoptEditingVersion(workID: work.id, versionID: stored.id, expectedRevision: 0)
    let copy = try store.createVirtualCopy(of: physical, name: "可继续显影")
    let fork = try store.photoWork(id: copy.id)
    XCTAssertEqual(fork.liveRecipe, candidate.recipe)
    XCTAssertEqual(fork.liveAlternateAppearance, .init(recipe: hdr))
    let alias = try store.editingVersion(id: fork.adoptedVersionID)
    var wrongRecipe = alias
    wrongRecipe.recipe.exposureEV = 3
    var wrongPresets = alias
    let preset = DevelopmentPresetRecord(id: "changed", name: "另一预设", group: "本地", kind: .user, patch: .init())
    wrongPresets.presetAdoptions = [try .init(record: preset, sourceID: physical.id, amount: 1,
      baseline: .init(), result: candidate.recipe, masks: nil)]
    for (name, altered) in [("changed-recipe", wrongRecipe), ("changed-presets", wrongPresets)] {
      try store.statement("UPDATE editing_versions SET data=? WHERE id=?", [try store.json(altered), alias.id])
      try await assertArchiveRejected(alias.id, name: name)
    }
  }

  private func assertArchiveRejected(_ versionID: String, name: String) async throws {
    XCTAssertThrowsError(try store.editingVersion(id: versionID)) { XCTAssertEqual($0 as? EditingError, .incompleteBackup) }
    let package = root.appendingPathComponent(name + ".rawmasterlibrary")
    do {
      _ = try await store.catalogActions.read("package", ["op": .string("backup"), "mode": .string("full"),
                                                          "destination": .string(package.path)])
      XCTFail("Cross-photo archive reference was packaged")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("invalid virtual copy archived result"), error.localizedDescription)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    XCTAssertThrowsError(try store.backupEditingLibrary(to: root.appendingPathComponent(name + "-editing"))) {
      XCTAssertEqual($0 as? EditingError, .incompleteBackup)
    }
  }
}
