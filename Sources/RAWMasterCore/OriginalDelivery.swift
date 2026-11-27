import Darwin
import Foundation

package enum OriginalDeliveryPhase: String, Codable, Sendable {
  case queued, running, paused, waiting, failed, cancelled, completed

  package var title: String {
    switch self {
    case .queued: "排队"
    case .running: "正在交付"
    case .paused: "已暂停，可继续"
    case .waiting: "等待核对"
    case .failed: "交付未完成"
    case .cancelled: "已取消"
    case .completed: "已完成"
    }
  }

  package var canResume: Bool { self != .completed && self != .running }
}

package struct OriginalDeliveryJob: Codable, Sendable, Identifiable {
  package let id: String
  package let title: String
  package let createdAt: Date
  package var phase: OriginalDeliveryPhase
  package var completed: Int
  package let total: Int
  package var error: String?
  package var report: ExportReport
  package var destinationPath: String
  package var historical = false

  fileprivate let libraryID: String
  fileprivate let directory: LocalDirectoryIdentity
  fileprivate var outputDirectory: LocalDirectoryIdentity? = nil
  fileprivate var manifestBasePath: String? = nil
}

private struct OriginalDeliveryCheckpoint: Codable {
  let relativePath: String
  var publishedPath: String? = nil
}

private struct OriginalSourceUnavailable: LocalizedError {
  var errorDescription: String? { "原件离线或不可读。请接回原件后继续。" }
}

extension LibraryStore {
  private static let originalJobPrefix = "originalDelivery.v1/job/"
  private static let originalPlanPrefix = "originalDelivery.v1/plan/"
  private static let originalItemPrefix = "originalDelivery.v1/item/"

  package func originalDeliveryHistory() throws -> [OriginalDeliveryJob] {
    try withReadSnapshot {
      let libraryID = try catalogLibraryIdentity()
      return try rows("SELECT value FROM metadata WHERE key GLOB ? ORDER BY rowid DESC", [Self.originalJobPrefix + "*"]).map {
        var job = try decode($0[0], OriginalDeliveryJob.self)
        job.historical = job.libraryID != libraryID
        // The workbench overlays live progress. A running record after a restart is resumable.
        if job.phase == .running { job.phase = .paused }
        return job
      }
    }
  }

  package func originalDeliveryJob(id: String) throws -> OriginalDeliveryJob {
    var job = try rawOriginalDeliveryJob(id: id)
    job.historical = try job.libraryID != catalogLibraryIdentity()
    if job.phase == .running { job.phase = .paused }
    return job
  }

  fileprivate func rawOriginalDeliveryJob(id: String) throws -> OriginalDeliveryJob {
    guard UUID(uuidString: id) != nil else { throw LibraryError.invalid("原件交付任务身份无效。") }
    return try locked {
      guard let raw = try rows("SELECT value FROM metadata WHERE key=?", [Self.originalJobPrefix + id]).first else {
        throw LibraryError.invalid("找不到所选原件交付任务。")
      }
      return try decode(raw[0], OriginalDeliveryJob.self)
    }
  }

  fileprivate func originalDeliveryPlan(_ job: OriginalDeliveryJob) throws -> PreparedOriginalExport {
    try locked {
      guard let raw = try rows("SELECT value FROM metadata WHERE key=?", [Self.originalPlanPrefix + job.id]).first else {
        throw LibraryError.invalid("原件交付缺少冻结的选片与清单。")
      }
      return try decode(raw[0], PreparedOriginalExport.self)
    }
  }

  fileprivate func originalDeliveryCheckpoints(_ job: OriginalDeliveryJob) throws -> [String: OriginalDeliveryCheckpoint] {
    let prefix = Self.originalItemPrefix + job.id + "/"
    return try locked {
      let values = try rows("SELECT key,value FROM metadata WHERE key GLOB ?", [prefix + "*"])
      return try Dictionary(uniqueKeysWithValues: values.map {
        (String($0[0].dropFirst(prefix.count)), try decode($0[1], OriginalDeliveryCheckpoint.self))
      })
    }
  }

  fileprivate func createOriginalDelivery(_ job: OriginalDeliveryJob, plan: PreparedOriginalExport) throws {
    try transaction {
      try statement("INSERT INTO metadata(key,value) VALUES(?,?)", [Self.originalJobPrefix + job.id, try json(job)])
      try statement("INSERT INTO metadata(key,value) VALUES(?,?)", [Self.originalPlanPrefix + job.id, try json(plan)])
    }
  }

  fileprivate func saveOriginalDelivery(_ job: OriginalDeliveryJob, item: (String, OriginalDeliveryCheckpoint)? = nil) throws {
    try transaction {
      guard try catalogLibraryIdentity() == job.libraryID else {
        throw LibraryError.invalid("副本可以查阅原交付历史。请在此资料库新建交付任务。")
      }
      try statement("UPDATE metadata SET value=? WHERE key=?", [try json(job), Self.originalJobPrefix + job.id])
      if let (id, checkpoint) = item {
        try statement("INSERT OR REPLACE INTO metadata(key,value) VALUES(?,?)",
                      [Self.originalItemPrefix + job.id + "/" + id, try json(checkpoint)])
      }
    }
  }
}

extension ExportService {
  private static let originalFolder = "RAWMaster精选"

  package func enqueueOriginalDelivery(id: UUID, ids: [String], destination: URL, manifestIDs: [String],
                                       formats: ExportFormats, csvLayout: ExportCSVLayout) throws -> OriginalDeliveryJob {
    let createdAt = Date.now
    let plan = try prepareOriginalExport(ids: ids, manifestIDs: manifestIDs, formats: formats, allowedAssetIDs: manifestIDs,
      csvLayout: csvLayout, createdAt: createdAt)
    let folder = FileSafety.canonical(destination)
    try FileSafety.checkTarget(folder, sources: durableOriginalProtectedRoots())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let identity = try LocalDirectoryIdentity(folder)
    let stem = id.uuidString.lowercased()
    let output = folder.appendingPathComponent(Self.originalFolder)
    let job = OriginalDeliveryJob(id: stem, title: ids.isEmpty ? "CSV / JSON 清单" : "交付精选原片",
      createdAt: createdAt, phase: .queued, completed: 0,
      total: ids.isEmpty ? plan.manifest.items.count : plan.copyIDs.count, error: nil,
      report: ExportReport(destinationPath: output.path), destinationPath: folder.path,
      libraryID: try store.catalogLibraryIdentity(), directory: identity)
    try store.createOriginalDelivery(job, plan: plan)
    return job
  }

  package func pauseOriginalDelivery() { control.pause() }

  package func cancelOriginalDelivery(id: String) throws {
    guard UUID(uuidString: id) != nil else { throw LibraryError.invalid("原件交付任务身份无效。") }
    let lease = try store.acquireImportLease("original-delivery-" + id)
    defer { lease.release() }
    var job = try store.rawOriginalDeliveryJob(id: id)
    try requireLocalDelivery(job)
    guard job.phase != .completed else { return }
    job.phase = .cancelled
    job.error = nil
    try store.saveOriginalDelivery(job)
  }

  package func resumeOriginalDelivery(id: String, destination: URL? = nil,
                                      progress: @escaping @Sendable (TaskProgress) -> Void) async throws -> OriginalDeliveryJob {
    try control.begin()
    defer { control.finish() }
    return try await withTaskCancellationHandler(operation: {
      try await Task.detached(priority: .userInitiated) {
        try self.runOriginalDelivery(id: id, destination: destination, progress: progress)
      }.value
    }, onCancel: { self.control.cancel() })
  }

  private func requireLocalDelivery(_ job: OriginalDeliveryJob) throws {
    guard try store.catalogLibraryIdentity() == job.libraryID else {
      throw LibraryError.invalid("副本可以查阅原交付历史。请在此资料库新建交付任务。")
    }
  }

  private func runOriginalDelivery(id: String, destination: URL?,
                                   progress: @escaping @Sendable (TaskProgress) -> Void) throws -> OriginalDeliveryJob {
    guard UUID(uuidString: id) != nil else { throw LibraryError.invalid("原件交付任务身份无效。") }
    let lease = try store.acquireImportLease("original-delivery-" + id)
    defer { lease.release() }
    var job = try store.rawOriginalDeliveryJob(id: id)
    try requireLocalDelivery(job)
    guard job.phase != .completed else { return job }
    let plan = try store.originalDeliveryPlan(job)
    var checkpoints = try store.originalDeliveryCheckpoints(job)
    let roots = try durableOriginalProtectedRoots()
    let selected = FileSafety.canonical(destination ?? URL(fileURLWithPath: job.destinationPath, isDirectory: true))
    let expectedDirectory = job.directory
    let output = selected.appendingPathComponent(Self.originalFolder, isDirectory: true)
    func checkDirectory(_ directory: URL, matching expected: LocalDirectoryIdentity) throws {
      guard let current = try? LocalDirectoryIdentity(directory), expected.matches(current) else {
        throw LibraryError.invalid("原交付目标离线或身份已变化。请接回原卷并重新选择同一目录。")
      }
    }
    func update(_ message: String) {
      progress(.init(title: job.title, completed: job.completed, total: job.total, message: message,
                     isRunning: job.phase == .running))
    }

    do {
      try control.check()
      do {
        try checkDirectory(selected, matching: expectedDirectory)
        _ = try originalOutputPath(Self.originalFolder, in: selected, protected: roots)
        if let expected = job.outputDirectory { try checkDirectory(output, matching: expected) }
        else {
          if !FileManager.default.fileExists(atPath: output.path) {
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
          }
          job.outputDirectory = try LocalDirectoryIdentity(output)
        }
      } catch {
        job.phase = .waiting; job.error = error.localizedDescription
        try store.saveOriginalDelivery(job)
        update(job.error ?? job.phase.title)
        return job
      }
      guard let expectedOutput = job.outputDirectory else { throw LibraryError.invalid("无法登记输出目录。") }
      let verifyTarget = {
        try self.control.check()
        try checkDirectory(selected, matching: expectedDirectory)
        try checkDirectory(output, matching: expectedOutput)
        _ = try self.originalOutputPath(Self.originalFolder, in: selected, protected: roots)
      }

      job.destinationPath = selected.path
      job.report.destinationPath = output.path
      job.report.errors = plan.manifest.missingFormats ?? []
      job.report.failed = job.report.errors.count
      job.phase = .running
      job.error = nil
      try store.saveOriginalDelivery(job)
      update("核对冻结范围与目标目录…")

      var manifest = plan.manifest
      var failures = [String]()
      var waitingForSource = false
      for index in manifest.items.indices where manifest.items[index].copyRequested {
        try verifyTarget()
        let asset = manifest.items[index].asset
        do {
          try deliverOriginal(asset, in: output, protected: roots, checkpoint: &checkpoints[asset.id],
            job: &job, verifyTarget: verifyTarget)
          manifest.items[index].status = "copied"
        } catch LibraryError.cancelled { throw LibraryError.cancelled }
        catch {
          try verifyTarget()
          waitingForSource = waitingForSource || error is OriginalSourceUnavailable
          failures.append(asset.filename + "：" + error.localizedDescription)
        }
        update(asset.filename)
      }
      job.report.errors += failures
      job.report.failed = job.report.errors.count
      if failures.isEmpty {
        try verifyTarget()
        if job.manifestBasePath == nil {
          job.manifestBasePath = output.path
          try store.saveOriginalDelivery(job)
        }
        let base = URL(fileURLWithPath: job.manifestBasePath ?? output.path, isDirectory: true)
        for index in manifest.items.indices where manifest.items[index].copyRequested {
          guard let item = checkpoints[manifest.items[index].asset.id], item.publishedPath != nil else {
            throw LibraryError.invalid("原件交付缺少文件收据。")
          }
          manifest.items[index].outputPath = base.appendingPathComponent(try FileSafety.safeRelative(item.relativePath)).path
        }
        manifest.status = job.report.failed == 0 ? "completed" : "partial"
        let stem = "selection-" + id
        let json = try originalOutputPath(stem + ".json", in: output, protected: roots)
        let csv = try originalOutputPath(stem + ".csv", in: output, protected: roots)
        let data = try Self.manifestFiles(manifest, layout: plan.csvLayout, allowedIDs: plan.allowedIDs, jsonName: json.lastPathComponent)
        try publishOriginalManifest(data.json, at: json, in: selected, verifyTarget: verifyTarget)
        try publishOriginalManifest(data.csv, at: csv, in: selected, verifyTarget: verifyTarget)
        job.report.manifestPath = json.path
        job.completed = job.total
        job.phase = .completed
      } else {
        job.phase = waitingForSource ? .waiting : .failed
        job.error = failures.first
      }
    } catch LibraryError.cancelled {
      job.phase = control.isPausing ? .paused : .cancelled
    } catch {
      job.phase = (try? checkDirectory(selected, matching: expectedDirectory)) == nil ? .waiting : .failed
      job.error = error.localizedDescription
    }
    try store.saveOriginalDelivery(job)
    update(job.error ?? job.phase.title)
    return job
  }

  private func durableOriginalProtectedRoots() throws -> [URL] {
    try store.withReadSnapshot {
      var roots = try protectedOriginalExportRoots()
      let package = store.databaseURL.deletingLastPathComponent()
      if package.pathExtension.caseInsensitiveCompare(LocalLibraryPackage.pathExtension) == .orderedSame { roots.append(package) }
      if let archive = try store.rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first {
        roots.append(URL(fileURLWithPath: archive))
      }
      roots.append(store.databaseURL)
      return roots
    }
  }

  private func originalOutputPath(_ relative: String, in directory: URL, protected: [URL]) throws -> URL {
    let target = directory.appendingPathComponent(try FileSafety.safeRelative(relative)).standardizedFileURL
    guard FileSafety.canonical(target).path == target.path, FileSafety.contains(directory, target) else {
      throw LibraryError.invalid("所选交付路径包含符号链接。")
    }
    try FileSafety.checkTarget(target, sources: protected)
    return target
  }

  private func deliverOriginal(_ asset: AssetRecord, in output: URL, protected: [URL],
                               checkpoint: inout OriginalDeliveryCheckpoint?, job: inout OriginalDeliveryJob,
                               verifyTarget: () throws -> Void) throws {
    if checkpoint?.publishedPath != nil { return }
    guard asset.importState == .ready, let hash = asset.contentHash, EditingFingerprint.isSHA256(hash.lowercased()) else {
      throw LibraryError.invalid("本次交付没有可验证的原件内容。")
    }
    let hashValue = hash.lowercased()
    let relative: String
    if let frozen = checkpoint { relative = frozen.relativePath }
    else {
      // Reserve a candidate before copying. A retry never chooses a second filename for this item.
      let requested = try originalOutputPath(asset.sessionID + "/" + asset.relativePath, in: output, protected: protected)
      relative = try availableOriginalPath(requested, under: output, hash: hashValue, bytes: asset.fileSize, protected: protected)
      let planned = OriginalDeliveryCheckpoint(relativePath: relative)
      try store.saveOriginalDelivery(job, item: (asset.id, planned))
      checkpoint = planned
    }
    let target = try originalOutputPath(relative, in: output, protected: protected)
    if try !matchingOriginal(target, hash: hashValue, bytes: asset.fileSize) {
      let current = try store.locked { try store.asset(asset.id) }
      guard FileManager.default.isReadableFile(atPath: current.resolvedURL.path),
        try FileSafety.stat(current.resolvedURL).size == asset.fileSize else { throw OriginalSourceUnavailable() }
      let result = try FileSafety.verifiedCopy(source: current.resolvedURL, target: target, expectedHash: hashValue,
        protectedRoots: protected, allowAlternateTarget: false, beforePublish: {
          try verifyTarget()
          _ = try self.originalOutputPath(relative, in: output, protected: protected)
        }, cancel: { try self.control.check() })
      guard result.0.path == target.path else { throw LibraryError.invalid("交付文件与已冻结位置不一致。") }
    }
    // Once the external write exists, seal its receipt even if a stop arrived during publication.
    try syncOriginalDirectories(from: target.deletingLastPathComponent(), through: output.deletingLastPathComponent())
    let receipt = OriginalDeliveryCheckpoint(relativePath: relative, publishedPath: target.path)
    job.completed += 1
    job.report.copied += 1
    do { try store.saveOriginalDelivery(job, item: (asset.id, receipt)) }
    catch {
      job.completed -= 1; job.report.copied -= 1
      throw error
    }
    checkpoint = receipt
  }

  private func availableOriginalPath(_ preferred: URL, under output: URL, hash: String,
                                     bytes: Int64, protected: [URL]) throws -> String {
    for suffix in 0...10_000 {
      try control.check()
      var candidate = preferred
      if suffix > 0 {
        candidate = preferred.deletingLastPathComponent().appendingPathComponent(
          preferred.deletingPathExtension().lastPathComponent + "-" + String(suffix))
        if !preferred.pathExtension.isEmpty { candidate.appendPathExtension(preferred.pathExtension) }
      }
      let relative = String(candidate.path.dropFirst(output.path.count + 1))
      _ = try originalOutputPath(relative, in: output, protected: protected)
      if !FileManager.default.fileExists(atPath: candidate.path) { return relative }
      if try matchingOriginal(candidate, hash: hash, bytes: bytes) { return relative }
    }
    throw LibraryError.invalid("无法为原件预留交付文件名。")
  }

  private func matchingOriginal(_ url: URL, hash: String, bytes: Int64) throws -> Bool {
    guard let stamp = try? FileSafety.stat(url), stamp.size == bytes else { return false }
    return try FileSafety.hash(url, cancel: { try self.control.check() }) == hash
  }

  private func publishOriginalManifest(_ data: Data, at url: URL, in selected: URL,
                                       verifyTarget: () throws -> Void) throws {
    try verifyTarget()
    if FileManager.default.fileExists(atPath: url.path) {
      let stamp = try FileSafety.stat(url)
      guard stamp.size == data.count, try Data(contentsOf: url) == data else {
        throw LibraryError.invalid("已存在的交付清单内容与此任务不同。")
      }
      try syncOriginalDirectories(from: url.deletingLastPathComponent(), through: selected)
      return
    }
    let temp = url.deletingLastPathComponent().appendingPathComponent(".rawmaster-" + UUID().uuidString + ".partial")
    try data.write(to: temp, options: .withoutOverwriting)
    defer { try? FileManager.default.removeItem(at: temp) }
    let handle = try FileHandle(forWritingTo: temp)
    defer { try? handle.close() }
    try handle.synchronize()
    try verifyTarget()
    guard renamex_np(temp.path, url.path, UInt32(RENAME_EXCL)) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    try syncOriginalDirectories(from: url.deletingLastPathComponent(), through: selected)
  }

  private func syncOriginalDirectories(from start: URL, through last: URL) throws {
    var directory = start
    let root = last.path
    while true {
      let fd = open(directory.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
      let result = fsync(fd)
      let code = errno
      close(fd)
      guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
      if directory.path == root { return }
      let parent = directory.deletingLastPathComponent()
      guard parent.path != directory.path else { throw LibraryError.invalid("无法核对交付路径。") }
      directory = parent
    }
  }
}
