import Foundation
import RAWMasterLibrary
import XCTest
@testable import RAWMasterCore

final class LocalLibraryPackageTests: XCTestCase {
  private func workspace(in parent: URL = FileManager.default.temporaryDirectory) throws -> URL {
    let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    addTeardownBlock { try FileManager.default.removeItem(at: root) }
    return root
  }

  func testSelectedLocationCreatesManifestAndRejectsUnknownOrExistingDocuments() throws {
    let root = try workspace()
    let missing = root.appendingPathComponent("不存在.rawmasterlibrary")
    XCTAssertThrowsError(try LocalLibraryPackage.inspect(missing))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    XCTAssertThrowsError(try LibraryStore(databaseURL: missing.appendingPathComponent("library.sqlite"), requireExisting: true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

    let package = try LocalLibraryPackage.create(at: root.appendingPathComponent("我的照片 2026"))
    XCTAssertEqual(package.kind, .working)
    XCTAssertEqual(package.name, "我的照片 2026")
    XCTAssertEqual(package.root.pathExtension, LocalLibraryPackage.pathExtension)
    XCTAssertEqual(try LocalLibraryPackage.inspect(package.database).libraryID, package.libraryID)
    XCTAssertTrue(FileManager.default.fileExists(atPath: package.root.appendingPathComponent("library.json").path))
    XCTAssertThrowsError(try LocalLibraryPackage.create(at: package.root))

    let foreign = root.appendingPathComponent("不相关.sqlite")
    let bytes = Data("foreign document".utf8)
    try bytes.write(to: foreign)
    XCTAssertThrowsError(try LocalLibraryPackage.inspect(foreign))
    XCTAssertEqual(try Data(contentsOf: foreign), bytes)
    XCTAssertFalse(FileManager.default.fileExists(atPath: foreign.path + "-wal"))
  }

  func testSameVolumeMovePreservesWriterIdentityAndRebasesPackageOwnedFiles() throws {
    let root = try workspace()
    let original = try LocalLibraryPackage.create(at: root.appendingPathComponent("照片"))
    let own = original.root.appendingPathComponent("Originals")
    let outside = root.appendingPathComponent("照片.rawmasterlibrary-extra")
    for directory in [own, outside] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false) }
    let managed = own.appendingPathComponent("managed.jpg"), external = outside.appendingPathComponent("external.jpg")
    try Data("managed pixels".utf8).write(to: managed)
    try Data("external pixels".utf8).write(to: external)
    do {
      let writer = try original.acquireWriter()
      XCTAssertThrowsError(try original.acquireWriter())
      let store = try LibraryStore(databaseURL: writer.prepare().database)
      _ = try store.configureEditingArchive(root: original.root.appendingPathComponent("EditingArchive"))
      _ = try store.admitLightroomOriginal(managed, projectID: nil)
      _ = try store.admitLightroomOriginal(external, projectID: nil)
      XCTAssertEqual(try store.loadAssets().count, 2)
    }
    let moved = root.appendingPathComponent("照片已移动.rawmasterlibrary")
    try FileManager.default.moveItem(at: original.root, to: moved)
    let selected = try LocalLibraryPackage.inspect(moved)
    XCTAssertEqual(selected.physicalIdentity, original.physicalIdentity)
    guard case .known = selected.relationship(to: []) else { return XCTFail("the same package must survive a rename") }
    let writer = try selected.acquireWriter()
    let activated = try writer.prepare()
    XCTAssertEqual(activated.libraryID, original.libraryID)
    let store = try LibraryStore(databaseURL: activated.database)
    let paths = try store.loadAssets().map { $0.resolvedURL.path }
    XCTAssertTrue(paths.contains(moved.appendingPathComponent("Originals/managed.jpg").path))
    XCTAssertTrue(paths.contains(external.path))
    XCTAssertEqual(try store.editingArchive().root.path, moved.appendingPathComponent("EditingArchive").path)
    let copies = try store.rows("SELECT DISTINCT path FROM lc_replicas")
    XCTAssertTrue(copies.contains([moved.appendingPathComponent("Originals/managed.jpg").path]))
    XCTAssertFalse(copies.contains([managed.path]))
  }

  func testFinderCopyIsIndependentAndLeavesOriginalImportHistoryUntouched() throws {
    let root = try workspace()
    let original = try LocalLibraryPackage.create(at: root.appendingPathComponent("项目甲"))
    let originalDevice: String
    let importID: String
    do {
      let store = try LibraryStore(databaseURL: original.database)
      let intake = root.appendingPathComponent("Camera Card")
      try FileManager.default.createDirectory(at: intake, withIntermediateDirectories: false)
      try Data("pending".utf8).write(to: intake.appendingPathComponent("image.jpg"))
      let pending = try store.prepareImportSession(root: intake, destination: nil, mode: .reference, projectName: "拍摄", projectID: nil, initialScreening: false)
      importID = pending.id
      originalDevice = store.deviceID
    }
    let copy = root.appendingPathComponent("项目甲副本.rawmasterlibrary")
    try FileManager.default.copyItem(at: original.root, to: copy)
    let opened = try LocalLibraryPackage.inspect(copy)
    guard case .copy = opened.relationship(to: []) else { return XCTFail("independent confirmation is required when the original is available") }
    let writer = try opened.acquireWriter()
    let activated = try writer.prepare(.independentCopy)
    XCTAssertNotEqual(activated.libraryID, original.libraryID)
    XCTAssertNotEqual(activated.physicalIdentity, original.physicalIdentity)
    let local = try LibraryStore(databaseURL: activated.database)
    XCTAssertNotEqual(local.deviceID, originalDevice)
    XCTAssertEqual(try local.loadSessions().first?.status, "pending")
    XCTAssertTrue(try local.isHistoricalTask(.importSession, id: importID))
    XCTAssertThrowsError(try local.requireLocalTask(.importSession, id: importID))
    let history = try XCTUnwrap(local.loadSessions().first)
    let fresh = try local.prepareImportSession(root: history.sourceURL, destination: nil, mode: history.mode, projectName: history.projectName, projectID: history.projectID, initialScreening: false)
    XCTAssertNotEqual(fresh.id, importID)
    XCTAssertFalse(try local.isHistoricalTask(.importSession, id: fresh.id))
    let source = try LibraryStore(databaseURL: original.database)
    XCTAssertEqual(try source.catalogLibraryIdentity(), original.libraryID)
    XCTAssertFalse(try source.isHistoricalTask(.importSession, id: importID))
    XCTAssertEqual(try source.loadSessions().map(\.id), [importID])
  }

  func testRecentRejectsAReplacementAndOffersCrossDeviceIdentityChoice() throws {
    let root = try workspace()
    let suite = "RAWMaster.LocalLibraryTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let original = try LocalLibraryPackage.create(at: root.appendingPathComponent("选择位置"))
    let imageVolume = ProcessInfo.processInfo.environment["RAWMASTER_TEST_LIBRARY_VOLUME"]
    let targetSpace = try imageVolume.map { path in
      let volume = URL(fileURLWithPath: path, isDirectory: true)
      XCTAssertNotEqual(try volume.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString,
                        try root.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString)
      return try workspace(in: volume)
    } ?? root
    let camera = original.root.appendingPathComponent("Originals", isDirectory: true)
    try FileManager.default.createDirectory(at: camera, withIntermediateDirectories: false)
    do {
      let source = try LibraryStore(databaseURL: original.database)
      var pending = try source.prepareImportSession(root: camera, destination: nil, mode: .reference, projectName: "待导入", projectID: nil, initialScreening: false)
      pending.sourceDirectoryIdentity = try LocalDirectoryIdentity(camera)
      try source.saveSession(pending)
    }
    let onlyCopy = targetSpace.appendingPathComponent("跨卷转移.rawmasterlibrary")
    try FileManager.default.copyItem(at: original.root, to: onlyCopy)
    LocalLibraryHistory.remember(original, defaults: defaults)
    let recent = try XCTUnwrap(LocalLibraryHistory.entries(defaults: defaults).first)
    try FileManager.default.removeItem(at: original.root)
    let replacement = try LocalLibraryPackage.create(at: original.root)
    XCTAssertThrowsError(try recent.resolve())
    XCTAssertNotEqual(replacement.libraryID, original.libraryID)
    let selected = try LocalLibraryPackage.inspect(onlyCopy)
    guard case .ambiguous = selected.relationship(to: [recent]) else { return XCTFail("ambiguous move needs confirmation") }
    let writer = try selected.acquireWriter()
    XCTAssertEqual(try writer.prepare(.keepIdentity).libraryID, original.libraryID)
    let local = try writer.openStore()
    let task = try XCTUnwrap(local.loadSessions().first)
    let movedSource = FileSafety.canonical(onlyCopy.appendingPathComponent("Originals", isDirectory: true))
    XCTAssertEqual(FileSafety.canonical(task.sourceURL).path, movedSource.path)
    XCTAssertTrue(try task.sourceDirectoryIdentity?.matches(LocalDirectoryIdentity(movedSource)) == true)
  }

  func testPre042CopyRecognizesShippedArchivePathOnAFreshProfile() throws {
    let root = try workspace()
    let original = root.appendingPathComponent("以前的照片.rawmasterlibrary")
    let previousArchive = original.appendingPathComponent("Editing Archive", isDirectory: true)
    do {
      let store = try LibraryStore(databaseURL: original.appendingPathComponent("library.sqlite"))
      _ = try store.configureEditingArchive(root: previousArchive)
    }
    let copy = root.appendingPathComponent("旧包的副本.rawmasterlibrary")
    try FileManager.default.copyItem(at: original, to: copy)
    let selected = try LocalLibraryPackage.inspect(copy)
    guard case .copy = selected.relationship(to: []) else { return XCTFail("pre-042 duplicate was not detected") }
    let writer = try selected.acquireWriter()
    XCTAssertThrowsError(try writer.prepare(.keepIdentity))
    let new = try writer.prepare(.independentCopy)
    XCTAssertNotEqual(new.libraryID, selected.libraryID)
    XCTAssertEqual(try writer.openStore().editingArchive().root.path, copy.appendingPathComponent("Editing Archive").path)
  }

  func testDamagedFinderCopyLeavesLibraryIdentityUntouched() throws {
    let root = try workspace()
    let original = try LocalLibraryPackage.create(at: root.appendingPathComponent("原库"))
    do {
      let store = try LibraryStore(databaseURL: original.database)
      _ = try store.configureEditingArchive(root: original.root.appendingPathComponent("Editing Archive", isDirectory: true))
    }
    let clone = root.appendingPathComponent("损坏的副本.rawmasterlibrary")
    try FileManager.default.copyItem(at: original.root, to: clone)
    try FileManager.default.removeItem(at: clone.appendingPathComponent("Editing Archive", isDirectory: true))
    let writer = try LocalLibraryPackage.inspect(clone).acquireWriter()
    XCTAssertThrowsError(try writer.prepare(.independentCopy))
    XCTAssertEqual(try LocalLibraryPackage.inspect(clone).libraryID, original.libraryID)
    XCTAssertEqual(try LocalLibraryPackage.inspect(original.root).libraryID, original.libraryID)
  }

  func testLegacyMigrationSnapshotsOpenWALAndKeepsExternalOriginal() throws {
    let root = try workspace()
    let legacyRoot = root.appendingPathComponent("旧资料库", isDirectory: true)
    let database = legacyRoot.appendingPathComponent("旧目录.sqlite")
    let source = try LibraryStore(databaseURL: database)
    let protected = root.appendingPathComponent("外置照片", isDirectory: true)
    try FileManager.default.createDirectory(at: protected, withIntermediateDirectories: false)
    let external = protected.appendingPathComponent("camera.jpg")
    try Data("externally referenced".utf8).write(to: external)
    let archive = legacyRoot.appendingPathComponent("EditingArchive", isDirectory: true)
    _ = try source.configureEditingArchive(root: archive)
    _ = try source.admitLightroomOriginal(external, projectID: nil)

    let legacy = try LocalLibraryPackage.inspect(database)
    XCTAssertEqual(legacy.kind, .legacy)
    let writer = try legacy.acquireWriter()
    let migrated = try writer.migrate(to: root.appendingPathComponent("迁移资料库"))
    let completed = try LibraryStore(databaseURL: migrated.database)
    XCTAssertEqual(migrated.libraryID, legacy.libraryID)
    XCTAssertEqual(try completed.loadAssets().map { $0.resolvedURL.path }, [external.path])
    XCTAssertEqual(try completed.editingArchive().root.path, migrated.root.appendingPathComponent("EditingArchive").path)
    XCTAssertEqual(try source.editingArchive().root.path, archive.path)
    XCTAssertEqual(try source.loadAssets().map { $0.resolvedURL.path }, [external.path])
  }

  func testLegacyMigrationDoesNotPublishWhenRequiredArchiveIsMissing() throws {
    let root = try workspace()
    let database = root.appendingPathComponent("旧库/library.sqlite")
    let archive = database.deletingLastPathComponent().appendingPathComponent("Editing Archive")
    let source = try LibraryStore(databaseURL: database)
    _ = try source.configureEditingArchive(root: archive)
    try FileManager.default.removeItem(at: archive)
    let writer = try LocalLibraryPackage.inspect(database).acquireWriter()
    let target = root.appendingPathComponent("迁移失败.rawmasterlibrary")
    XCTAssertThrowsError(try writer.migrate(to: target))
    XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    XCTAssertEqual(try source.catalogLibraryIdentity(), writer.package.libraryID)
  }

  func testCatalogBackupRestoresIndependentPackageWithoutRepointingUncopiedOriginals() throws {
    let root = try workspace()
    let original = try LocalLibraryPackage.create(at: root.appendingPathComponent("备份原库"))
    let source = try LibraryStore(databaseURL: original.database)
    let sourceRoot = original.root.appendingPathComponent("Originals", isDirectory: true)
    try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: false)
    let originalFile = sourceRoot.appendingPathComponent("source.jpg")
    try Data("same original".utf8).write(to: originalFile)
    _ = try source.admitLightroomOriginal(originalFile, projectID: nil)
    let backup = root.appendingPathComponent("仅目录备份.rawmasterlibrary")
    let _: CatalogJSON = try LibraryEngine.shared().request("package", at: source.databaseURL,
      payload: ["op": "backup", "mode": "catalog", "destination": backup.path], as: CatalogJSON.self)

    let document = try LocalLibraryPackage.inspect(backup)
    XCTAssertEqual(document.kind, .backup)
    XCTAssertThrowsError(try document.acquireWriter())
    let restored = try document.restore(to: root.appendingPathComponent("恢复的照片"))
    XCTAssertEqual(restored.kind, .working)
    XCTAssertNotEqual(restored.libraryID, original.libraryID)
    let rebuilt = try LibraryStore(databaseURL: restored.database)
    XCTAssertEqual(try rebuilt.loadAssets().map { $0.resolvedURL.path }, [originalFile.path])
    XCTAssertEqual(try source.catalogLibraryIdentity(), original.libraryID)
  }
}
