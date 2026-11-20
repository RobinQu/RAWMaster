import Foundation
import CryptoKit
import Darwin

final class ImportExecutionLease {
  private var descriptor: Int32
  init(_ descriptor: Int32) { self.descriptor = descriptor }
  func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
  deinit { release() }
}

extension LibraryStore {
  func acquireImportLease(_ sessionID: String) throws -> ImportExecutionLease {
    try FileManager.default.createDirectory(at: importLockDirectory, withIntermediateDirectories: true)
    let stem = SHA256.hash(data: Data(sessionID.utf8)).map { String(format: "%02x", $0) }.joined()
    let path = importLockDirectory.appendingPathComponent(stem).path
    let descriptor = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw LibraryError.invalid("无法锁定导入会话") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { Darwin.close(descriptor); throw LibraryError.busy }
    return ImportExecutionLease(descriptor)
  }

  func stableJSON<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(value)
  }
  func prepareImportSession(root: URL, destination: URL?, mode: ImportMode, projectName: String, projectID: String?, initialScreening: Bool) throws -> ImportSession {
    try transaction {
      let project: ProjectRecord
      if let projectID {
        guard let p = try loadProjects().first(where: { $0.id == projectID }) else { throw LibraryError.invalid("项目不存在") }
        project = p
      } else {
        project = ProjectRecord(name: projectName.isEmpty ? root.lastPathComponent : projectName)
        try statement("INSERT INTO projects VALUES(?,?)", [project.id, try json(project)])
      }
      let workflows = try loadWorkflows()
      let closed = Set(workflows.filter { $0.phase == .closed }.map(\.sessionID))
      let activeTriage = Set(workflows.filter { $0.phase == .ingesting || $0.phase == .screening }.map(\.sessionID))
      let existing = try loadSessions().first { !closed.contains($0.id) && (!initialScreening || activeTriage.contains($0.id)) && $0.projectID == project.id && (FileSafety.canonical($0.sourceURL) == root || FileSafety.canonical($0.effectiveSourceURL) == root) }
      if let existing {
        guard existing.mode == mode, (existing.effectiveManagedRoot ?? existing.destinationPath) == destination.map({ FileSafety.canonical($0).path }) else { throw LibraryError.invalid("该来源已存在于此项目，接入方式或目标不同；请恢复原会话，或选择新项目") }
        return existing
      }
      let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: root.path, destinationPath: destination.map { FileSafety.canonical($0).path }, mode: mode)
      try statement("INSERT INTO sessions VALUES(?,?)", [session.id, try json(session)])
      if initialScreening { try writeWorkflow(SessionWorkflow(sessionID: session.id, projectID: project.id, isNewProject: projectID == nil)) }
      return session
    }
  }
  func createTriageSchema() throws {
    for (table, key) in [("session_workflows", "id"), ("project_admissions", "asset_id"), ("triage_records", "asset_id"), ("capture_pairs", "id"), ("pair_dismissals", "id"), ("triage_commands", "id"), ("quality_evidence", "asset_id"), ("asset_tags", "asset_id"), ("workflow_completions", "id")] {
      try exec("CREATE TABLE \(table)(\(key) TEXT PRIMARY KEY, data TEXT NOT NULL)")
    }
    for session in try loadSessions() {
      let workflow = SessionWorkflow(sessionID: session.id, projectID: session.projectID, isNewProject: false, phase: .legacyHistory)
      try writeWorkflow(workflow)
    }
    for a in try loadAssets() {
      try writeAdmission(ProjectAdmission(assetID: a.id, projectID: a.projectID))
    }
    try exec("PRAGMA user_version=4")
  }
  func writeWorkflow(_ workflow: SessionWorkflow) throws {
    try statement("INSERT INTO session_workflows VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", [workflow.id, try json(workflow)])
  }
  func writeAdmission(_ admission: ProjectAdmission) throws {
    try statement("INSERT OR IGNORE INTO project_admissions VALUES(?,?)", [admission.assetID, try json(admission)])
  }
  func workflow(_ id: String) throws -> SessionWorkflow? {
    guard let row = try rows("SELECT data FROM session_workflows WHERE id=?", [id]).first else { return nil }
    return try decode(row[0], SessionWorkflow.self)
  }
  func assertSessionWritable(_ sessionID: String) throws {
    if try workflow(sessionID)?.phase == .closed { throw LibraryError.invalid("初筛会话已关闭，请从导入历史恢复素材或开始新会话") }
  }
  func bumpWorkflow(_ sessionID: String) throws {
    if var w = try workflow(sessionID) { w.revision += 1; try writeWorkflow(w) }
  }
  func beginTriage(_ session: ImportSession, isNewProject: Bool) throws {
    try transaction {
      guard try workflow(session.id) == nil else { throw LibraryError.invalid("会话已存在") }
      try writeWorkflow(SessionWorkflow(sessionID: session.id, projectID: session.projectID, isNewProject: isNewProject))
    }
  }
  func setImportActive(_ sessionID: String, active: Bool) throws {
    try transaction {
      try assertSessionWritable(sessionID)
      if var w = try workflow(sessionID) {
        w.importActive = active
        if w.phase != .legacyHistory { w.phase = active ? .ingesting : .screening }
        w.revision += 1
        try writeWorkflow(w)
      }
    }
  }
  public func loadWorkflows() throws -> [SessionWorkflow] {
    try locked { try rows("SELECT data FROM session_workflows ORDER BY rowid").map { try decode($0[0], SessionWorkflow.self) } }
  }
  public func loadAdmissions() throws -> [ProjectAdmission] {
    try locked { try rows("SELECT data FROM project_admissions ORDER BY rowid").map { try decode($0[0], ProjectAdmission.self) } }
  }
  public func publishedProjects() throws -> [ProjectRecord] {
    try locked {
      let workflows = try loadWorkflows(), admitted = Set(try loadAdmissions().map(\.projectID))
      let hidden = Set(workflows.filter { $0.isNewProject && !admitted.contains($0.projectID) }.map(\.projectID))
      return try loadProjects().filter { !hidden.contains($0.id) }
    }
  }
  public func loadTriageRecords(sessionID: String? = nil) throws -> [TriageRecord] {
    try locked {
      let values = try rows("SELECT data FROM triage_records ORDER BY rowid").map { try decode($0[0], TriageRecord.self) }
      guard let sessionID else { return values }
      let ids = Set(try loadAssets(sessionID: sessionID).map(\.id))
      return values.filter { ids.contains($0.assetID) }
    }
  }
  public func loadCapturePairs(sessionID: String? = nil) throws -> [CapturePair] {
    try locked {
      try rows("SELECT data FROM capture_pairs ORDER BY rowid").map { try decode($0[0], CapturePair.self) }.filter { sessionID == nil || $0.sessionID == sessionID }
    }
  }
  public func loadQualityEvidence(sessionID: String? = nil) throws -> [TriageQualityEvidence] {
    try locked {
      let values = try rows("SELECT data FROM quality_evidence ORDER BY rowid").map { try decode($0[0], TriageQualityEvidence.self) }
      guard let sessionID else { return values }
      let ids = Set(try loadAssets(sessionID: sessionID).map(\.id))
      return values.filter { ids.contains($0.assetID) }
    }
  }
  public func loadTags() throws -> [String: [String]] {
    try locked { try Dictionary(uniqueKeysWithValues: rows("SELECT asset_id,data FROM asset_tags").map { ($0[0], try decode($0[1], [String].self)) }) }
  }
  public func setTags(ids: [String], tags: [String]) throws {
    if ids.isEmpty { return }
    _ = try commitTagMutation(previewTagMutation(ids: ids, mode: .replace, tags: tags))
  }
  public func loadTriageCommands(sessionID: String? = nil) throws -> [TriageCommand] {
    try locked { try rows("SELECT data FROM triage_commands ORDER BY rowid DESC").map { try decode($0[0], TriageCommand.self) }.filter { sessionID == nil || $0.sessionID == sessionID } }
  }
  public func updateTriage(ids: [String], disposition: TriageDisposition) throws -> TriageCommand {
    try transaction {
      let assets = try Array(Set(ids)).sorted().map { try asset($0) }
      guard let session = assets.first?.sessionID, assets.allSatisfy({ $0.sessionID == session }), let w = try workflow(session), w.phase != .legacyHistory else { throw LibraryError.invalid("请选择同一初筛会话的素材") }
      try assertSessionWritable(session)
      let existing = Dictionary(uniqueKeysWithValues: try loadTriageRecords(sessionID: session).map { ($0.assetID, $0) })
      let before = assets.map { existing[$0.id] ?? TriageRecord(assetID: $0.id) }
      let commandID = UUID().uuidString
      let after = before.map { TriageRecord(assetID: $0.assetID, disposition: disposition, revision: $0.revision + 1, logicalWriterID: commandID) }
      for record in after { try writeTriage(record) }
      let command = TriageCommand(id: commandID, sessionID: session, before: before, after: after, restored: false)
      try statement("INSERT INTO triage_commands VALUES(?,?)", [command.id, try json(command)])
      try bumpWorkflow(session)
      return command
    }
  }
  func writeTriage(_ record: TriageRecord) throws {
    try statement("INSERT INTO triage_records VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data", [record.assetID, try json(record)])
  }
  public func undoTriage(commandID: String) throws {
    try transaction {
      guard let row = try rows("SELECT data FROM triage_commands WHERE id=?", [commandID]).first else { throw LibraryError.invalid("初筛操作不存在") }
      var command = try decode(row[0], TriageCommand.self)
      try assertSessionWritable(command.sessionID)
      guard !command.restored else { return }
      let current = Dictionary(uniqueKeysWithValues: try loadTriageRecords(sessionID: command.sessionID).map { ($0.assetID, $0) })
      for after in command.after {
        guard let now = current[after.assetID], now.logicalWriterID == command.id, now.disposition == after.disposition else { throw LibraryError.invalid("初筛处置已再次修改，不能覆盖后续操作") }
      }
      for before in command.before {
        try writeTriage(TriageRecord(assetID: before.assetID, disposition: before.disposition, revision: (current[before.assetID]?.revision ?? 0) + 1, logicalWriterID: before.logicalWriterID))
      }
      command.restored = true
      try statement("UPDATE triage_commands SET data=? WHERE id=?", [try json(command), command.id])
      try bumpWorkflow(command.sessionID)
    }
  }
  public func saveQualityEvidence(_ evidence: TriageQualityEvidence) throws {
    try transaction {
      let a = try asset(evidence.assetID)
      try assertSessionWritable(a.sessionID)
      guard a.importState == .ready, a.contentHash == evidence.contentHash, a.fileSize == evidence.fileSize else { throw LibraryError.invalid("素材版本变化，质量证据已过期") }
      guard !evidence.methodVersion.isEmpty, evidence.metrics.values.allSatisfy({ $0.isFinite }) else { throw LibraryError.invalid("质量证据无效") }
      try statement("INSERT INTO quality_evidence VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data", [a.id, try json(evidence)])
      try bumpWorkflow(a.sessionID)
    }
  }
  func pairKey(_ first: String, _ second: String) -> String { [first, second].sorted().joined(separator: ":") }
  func assertPairMaintenanceAllowed(sessionID: String, ids: [String]) throws {
    let phase = try workflow(sessionID)?.phase
    if phase == .closed || phase == .legacyHistory || phase == nil {
      let admitted = Set(try loadAdmissions().map(\.assetID))
      guard Set(ids).isSubset(of: admitted) else { throw LibraryError.invalid("项目维护只能关联已纳入素材，请先从导入历史恢复文件") }
    }
  }
  public func confirmCapturePair(rawAssetID: String, jpegAssetID: String) throws -> CapturePair {
    try transaction {
      let raw = try asset(rawAssetID), jpeg = try asset(jpegAssetID)
      guard raw.sessionID == jpeg.sessionID, raw.projectID == jpeg.projectID, CaptureFileFormat.isRAW(raw.filename), CaptureFileFormat.isJPEG(jpeg.filename) else { throw LibraryError.invalid("配对需要同会话的一个RAW和一个JPEG") }
      try assertPairMaintenanceAllowed(sessionID: raw.sessionID, ids: [raw.id, jpeg.id])
      return try insertPair(raw: raw, jpeg: jpeg, manual: true)
    }
  }
  func insertPair(raw: AssetRecord, jpeg: AssetRecord, manual: Bool) throws -> CapturePair {
    let pairs = try loadCapturePairs(sessionID: raw.sessionID)
    if let exact = pairs.first(where: { $0.rawAssetID == raw.id && $0.jpegAssetID == jpeg.id }) { return exact }
    guard pairs.allSatisfy({ Set($0.assetIDs).isDisjoint(with: [raw.id, jpeg.id]) }) else { throw LibraryError.invalid("文件已有配对，请先解除原关联") }
    let pair = CapturePair(sessionID: raw.sessionID, rawAssetID: raw.id, jpegAssetID: jpeg.id, isManual: manual)
    try statement("INSERT INTO capture_pairs VALUES(?,?)", [pair.id, try json(pair)])
    if manual { try statement("DELETE FROM pair_dismissals WHERE id=?", [pairKey(raw.id, jpeg.id)]) }
    try bumpWorkflow(raw.sessionID)
    return pair
  }
  public func unlinkCapturePair(id: String) throws {
    try transaction {
      guard let pair = try loadCapturePairs().first(where: { $0.id == id }) else { throw LibraryError.invalid("配对不存在") }
      try assertPairMaintenanceAllowed(sessionID: pair.sessionID, ids: pair.assetIDs)
      try statement("DELETE FROM capture_pairs WHERE id=?", [id])
      try statement("INSERT OR REPLACE INTO pair_dismissals VALUES(?,?)", [pairKey(pair.rawAssetID, pair.jpegAssetID), "{}"])
      try bumpWorkflow(pair.sessionID)
    }
  }
  public func scanCapturePairs(sessionID: String) throws -> [CapturePair] {
    try transaction {
      let phase = try workflow(sessionID)?.phase
      let admitted = Set(try loadAdmissions().map(\.assetID))
      let assets = try loadAssets(sessionID: sessionID).filter { phase == .ingesting || phase == .screening || admitted.contains($0.id) }
      let byKey = Dictionary(grouping: assets) { a -> String in
        let path = URL(fileURLWithPath: a.relativePath)
        return path.deletingPathExtension().path.precomposedStringWithCanonicalMapping
      }
      let dismissed = Set(try rows("SELECT id FROM pair_dismissals").map { $0[0] })
      var paired = Set(try loadCapturePairs(sessionID: sessionID).flatMap(\.assetIDs))
      for key in byKey.keys.sorted() {
        let candidates = byKey[key]!
        let raw = candidates.filter { CaptureFileFormat.isRAW($0.filename) }, jpeg = candidates.filter { CaptureFileFormat.isJPEG($0.filename) }
        guard raw.count == 1, jpeg.count == 1 else { continue }
        let r = raw[0], j = jpeg[0]
        guard !paired.contains(r.id), !paired.contains(j.id), !dismissed.contains(pairKey(r.id, j.id)), r.importState == .ready, j.importState == .ready,
          let rt = r.capturedAt, let jt = j.capturedAt, abs(rt.timeIntervalSince(jt)) < 0.001,
          let rc = r.camera?.trimmingCharacters(in: .whitespacesAndNewlines), let jc = j.camera?.trimmingCharacters(in: .whitespacesAndNewlines), !rc.isEmpty, rc == jc,
          r.width != nil, r.height != nil, r.width == j.width, r.height == j.height else { continue }
        // This transaction and its incrementally updated paired set already
        // enforce exclusivity. Avoid decoding every prior pair for each insert.
        let pair = CapturePair(sessionID: sessionID, rawAssetID: r.id, jpegAssetID: j.id, isManual: false)
        try statement("INSERT INTO capture_pairs VALUES(?,?)", [pair.id, try json(pair)])
        try bumpWorkflow(sessionID)
        paired.formUnion([r.id, j.id])
      }
      return try loadCapturePairs(sessionID: sessionID)
    }
  }
  func completionFingerprint(sessionID: String) throws -> String {
    struct Snapshot: Encodable {
      var session: ImportSession
      var workflow: SessionWorkflow
      var assets: [AssetRecord]
      var records: [TriageRecord]
      var pairs: [CapturePair]
      var groups: [CaptureGroup]
      var evidence: [TriageQualityEvidence]
    }
    guard let session = try loadSessions().first(where: { $0.id == sessionID }), let workflow = try workflow(sessionID) else { throw LibraryError.invalid("初筛会话不存在") }
    let assets = try loadAssets(sessionID: sessionID).sorted { $0.id < $1.id }
    let ids = Set(assets.map(\.id))
    let snapshot = Snapshot(session: session, workflow: workflow, assets: assets,
      records: try loadTriageRecords(sessionID: sessionID).sorted { $0.id < $1.id }, pairs: try loadCapturePairs(sessionID: sessionID).sorted { $0.id < $1.id },
      groups: try loadGroups().filter { !Set($0.assetIDs).isDisjoint(with: ids) }.sorted { $0.id < $1.id }, evidence: try loadQualityEvidence(sessionID: sessionID).sorted { $0.id < $1.id })
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    return SHA256.hash(data: try encoder.encode(snapshot)).map { String(format: "%02x", $0) }.joined()
  }
  func necessarySequenceIDs(_ assets: [AssetRecord]) throws -> Set<String> {
    let ids = Set(assets.map(\.id))
    return Set(try loadGroups().filter { !["连拍", "普通", "相似", "burst", "similar"].contains($0.kind.lowercased()) }.flatMap(\.includedAssetIDs)).intersection(ids)
  }
  public func previewCompletion(sessionID: String, acknowledgeManualAnalysis: Bool = false) throws -> CompletionPreview {
    try locked {
      guard let w = try workflow(sessionID), w.phase != .legacyHistory, let session = try loadSessions().first(where: { $0.id == sessionID }) else { throw LibraryError.invalid("请选择活动初筛会话") }
      try assertSessionWritable(sessionID)
      let assets = try loadAssets(sessionID: sessionID), records = Dictionary(uniqueKeysWithValues: try loadTriageRecords(sessionID: sessionID).map { ($0.assetID, $0) })
      let protected = try necessarySequenceIDs(assets)
      var admit: [String] = [], exclude: [String] = [], sequence: [String] = [], review: [String] = [], issues: [String] = []
      if w.importActive || ["pending", "scanning", "importing"].contains(session.status) { issues.append("素材接入仍在进行，请完成或恢复接入") }
      if session.scanCompleted != true { issues.append("来源扫描未完成，范围尚未封存") }
      for a in assets {
        let disposition = records[a.id]?.disposition ?? .pending
        let required = protected.contains(a.id)
        if disposition == .excluded && !required { exclude.append(a.id); continue }
        if a.importState != .ready || a.availability != .available { issues.append("\(a.filename)：接入未完成或原片不可用，请重试或明确排除") }
        admit.append(a.id)
        if disposition == .review { review.append(a.id) }
        if disposition == .excluded && required { sequence.append(a.id) }
      }
      let analysed = Set(try loadQualityEvidence(sessionID: sessionID).map(\.assetID))
      let pairs = try loadCapturePairs(sessionID: sessionID)
      let admitted = Set(admit)
      let pairCount = pairs.filter { Set($0.assetIDs).isSubset(of: admitted) }.count
      return CompletionPreview(id: UUID().uuidString, sessionID: sessionID, projectID: w.projectID, fingerprint: try completionFingerprint(sessionID: sessionID), admittedAssetIDs: admit.sorted(), excludedAssetIDs: exclude.sorted(), sequenceOnlyAssetIDs: sequence.sorted(), reviewAssetIDs: review.sorted(), issues: issues, unanalysedCount: assets.filter { !analysed.contains($0.id) }.count, captureCount: admit.count - pairCount, manualAnalysisAcknowledged: acknowledgeManualAnalysis)
    }
  }
  public func commitCompletion(_ preview: CompletionPreview) throws -> SessionWorkflow {
    let lease = try acquireImportLease(preview.sessionID)
    defer { lease.release() }
    return try transaction {
      if let prior = try rows("SELECT data FROM workflow_completions WHERE id=?", [preview.id]).first {
        let committed = try decode(prior[0], CompletionPreview.self)
        guard try stableJSON(committed) == stableJSON(preview), let w = try workflow(preview.sessionID) else { throw LibraryError.invalid("重复请求与原完成摘要不一致") }
        return w
      }
      let fresh = try previewCompletion(sessionID: preview.sessionID, acknowledgeManualAnalysis: preview.manualAnalysisAcknowledged)
      guard preview.canCommit, fresh.canCommit, fresh.fingerprint == preview.fingerprint, fresh.projectID == preview.projectID, fresh.admittedAssetIDs == preview.admittedAssetIDs, fresh.excludedAssetIDs == preview.excludedAssetIDs, fresh.sequenceOnlyAssetIDs == preview.sequenceOnlyAssetIDs, fresh.reviewAssetIDs == preview.reviewAssetIDs, fresh.unanalysedCount == preview.unanalysedCount, fresh.captureCount == preview.captureCount else { throw LibraryError.invalid("完成摘要已过期或仍有异常，请刷新后再确认") }
      for id in fresh.admittedAssetIDs { try writeAdmission(ProjectAdmission(assetID: id, projectID: fresh.projectID, sequenceOnly: fresh.sequenceOnlyAssetIDs.contains(id))) }
      var w = try workflow(preview.sessionID)!
      w.phase = .closed; w.importActive = false; w.closedAt = Date(); w.manualAnalysisAcknowledged = preview.manualAnalysisAcknowledged; w.revision += 1
      try writeWorkflow(w)
      try statement("INSERT INTO workflow_completions VALUES(?,?)", [preview.id, try json(preview)])
      try operation(entity: preview.sessionID, action: "completeTriage", payload: try json(preview))
      return w
    }
  }
  public func restoreArchivedAssets(sessionID: String, assetIDs: [String]) throws -> [String] {
    try transaction {
      guard let w = try workflow(sessionID), w.phase == .closed || w.phase == .legacyHistory else { throw LibraryError.invalid("请先完成初筛，再从历史恢复") }
      let assets = try loadAssets(sessionID: sessionID), lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
      var requested = Set(assetIDs)
      guard requested.isSubset(of: Set(lookup.keys)) else { throw LibraryError.invalid("恢复范围不属于此会话") }
      for pair in try loadCapturePairs(sessionID: sessionID) where !requested.isDisjoint(with: pair.assetIDs) { requested.formUnion(pair.assetIDs) }
      let admitted = Set(try loadAdmissions().map(\.assetID)), needed = requested.subtracting(admitted)
      for id in needed {
        guard let a = lookup[id] else { throw LibraryError.invalid("恢复文件不存在") }
        guard a.importState == .ready, a.contentHash != nil else {
          throw LibraryError.invalid("该文件从未完成核验，请新建导入会话重新接入；旧历史记录保留")
        }
        guard a.availability == .available else { throw LibraryError.invalid("恢复文件尚未可用，请先找回原片") }
      }
      for id in needed { try writeAdmission(ProjectAdmission(assetID: id, projectID: w.projectID)) }
      if !needed.isEmpty { try operation(entity: sessionID, action: "restoreTriageAssets", payload: try json(needed.sorted())) }
      return needed.sorted()
    }
  }
  public func exportSelection(ids: [String], formats: ExportFormats = .allOriginals, allowedAssetIDs: [String]? = nil) throws -> ExportSelection {
    try locked {
      let assets = try loadAssets(), lookup = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
      let admissions = try loadAdmissions()
      let admitted = Set(admissions.map(\.assetID))
      let allowed = allowedAssetIDs.map { Set($0).intersection(admitted) } ?? admitted
      let implicitEligible = Set(admissions.filter { !$0.sequenceOnly }.map(\.assetID)).union(ids).intersection(allowed)
      guard Set(ids).isSubset(of: admitted), Set(ids).isSubset(of: Set(lookup.keys)) else { throw LibraryError.invalid("交付仅支持已纳入项目的素材，请先完成初筛") }
      guard Set(ids).isSubset(of: allowed) else { throw LibraryError.invalid("交付选择超出当前筛选范围") }
      let pairs = try loadCapturePairs()
      var pairByAsset: [String: CapturePair] = [:]
      for pair in pairs { for id in pair.assetIDs { pairByAsset[id] = pair } }
      var selected = Set(ids)
      if formats != .allOriginals {
        for pair in pairs where !selected.isDisjoint(with: pair.assetIDs) { selected.formUnion(Set(pair.assetIDs).intersection(implicitEligible)) }
      }
      var missing: [String] = []
      if formats == .rawOnly || formats == .jpegOnly || formats == .both {
        for id in Set(ids).sorted() {
          guard let a = lookup[id] else { continue }
          let pair = pairByAsset[id]
          let event = (pair?.assetIDs ?? [id]).compactMap { lookup[$0] }.filter { implicitEligible.contains($0.id) }
          if (formats == .rawOnly || formats == .both) && !event.contains(where: { CaptureFileFormat.isRAW($0.filename) }) { missing.append("\(a.filename)：\(allowedAssetIDs == nil ? "没有已纳入的RAW文件" : "当前交付范围没有RAW文件")") }
          if (formats == .jpegOnly || formats == .both) && !event.contains(where: { CaptureFileFormat.isJPEG($0.filename) }) { missing.append("\(a.filename)：\(allowedAssetIDs == nil ? "没有已纳入的JPEG文件" : "当前交付范围没有JPEG文件")") }
        }
      }
      let result = selected.compactMap { lookup[$0] }.filter { a in
        switch formats { case .rawOnly: return CaptureFileFormat.isRAW(a.filename); case .jpegOnly: return CaptureFileFormat.isJPEG(a.filename); case .both: return CaptureFileFormat.isRAW(a.filename) || CaptureFileFormat.isJPEG(a.filename); case .allOriginals: return true }
      }
      return ExportSelection(assetIDs: result.map(\.id).sorted(), totalBytes: result.reduce(0) { $0 + $1.fileSize }, missingFormats: Array(Set(missing)).sorted())
    }
  }
}
