import CSQLite
import Darwin
import Foundation

/// Uses the same on-disk session fence as import execution, including other connections.
final class AutomaticGroupingScopeLease: @unchecked Sendable {
  private let descriptor: Int32
  init(_ descriptor: Int32) { self.descriptor = descriptor }
  deinit { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

extension LibraryStore {
  func acquireAutomaticGroupingLease(_ sessionID: String) throws -> AutomaticGroupingScopeLease {
    let path: String = try locked {
      guard let raw = sqlite3_db_filename(db, "main") else { throw LibraryError.invalid("资料库没有文件路径") }
      return String(cString: raw)
    }
    let database = FileSafety.canonical(URL(fileURLWithPath: path))
    let directory = database.deletingLastPathComponent().appendingPathComponent(
      "." + database.lastPathComponent + ".imports", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent(LocationIdentity.digest(Data(sessionID.utf8)))
    let descriptor = Darwin.open(file.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
    guard descriptor >= 0 else { throw LibraryError.invalid("无法锁定自动分组会话") }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(descriptor); throw LibraryError.busy
    }
    return AutomaticGroupingScopeLease(descriptor)
  }
  private func automaticRunKey(_ sessionID: String) -> String {
    "automatic-grouping.run.v1:" + sessionID
  }
  public func automaticGroupingRun(sessionID: String) throws -> AutomaticGroupingRunRecord? {
    try locked {
      guard let row = try rows("SELECT value FROM metadata WHERE key=?", [automaticRunKey(sessionID)]).first else { return nil }
      return try decode(row[0], AutomaticGroupingRunRecord.self)
    }
  }
  func saveAutomaticGroupingRun(_ record: AutomaticGroupingRunRecord) throws {
    try statement("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
                  [automaticRunKey(record.sessionID), try json(record)])
  }
  /// Full history is intentional: removing a member or undoing a group must not erase protection.
  func automaticGroupingSnapshot(sessionID: String, runID: String) throws -> AutomaticGroupingInput {
    try locked {
      guard let sessionRow = try rows("SELECT data FROM sessions WHERE id=?", [sessionID]).first else {
        throw LibraryError.invalid("自动分组会话不存在")
      }
      let session = try decode(sessionRow[0], ImportSession.self)
      let assets = SequenceBaseOrder.sorted(try loadAssets(sessionID: sessionID), sessions: [session])
      guard session.status == "completed", session.scanCompleted == true,
        assets.allSatisfy({ $0.importState == .ready && $0.projectID == session.projectID })
      else { throw LibraryError.invalid("只有完整导入会话可以自动分组") }
      let revisions = try assets.map { asset -> Int in
        guard let text = try rows("SELECT revision FROM assets WHERE id=?", [asset.id]).first?.first,
          let revision = Int(text), revision >= 0 else { throw LibraryError.invalid("素材版本无效") }
        return revision
      }
      let allIDs = Set(assets.map(\.id))
      let memberships = try rows("SELECT group_id,asset_id,position,included FROM membership ORDER BY group_id,position,asset_id")
      let history = try rows("SELECT id,data FROM group_commands ORDER BY rowid")
      var protected = Set(memberships.map { $0[1] }).intersection(allIDs)
      for row in history {
        let record = try decode(row[1], GroupCommandEnvelope.self).record
        protected.formUnion((record.before + record.after).flatMap(\.assetIDs).filter { allIDs.contains($0) })
      }
      // Include the full group causal state conservatively. A concurrent manual edit, even an
      // undo that restores equal values, invalidates the prepared analysis. Ledger writes are excluded.
      let groupRows = try rows("SELECT id,project_id,data FROM groups_data ORDER BY id")
      let domains = try rows("SELECT * FROM group_domains ORDER BY group_id,domain")
      struct Scope: Encodable {
        let version, session: String
        let assets: [AssetRecord]
        let revisions: [Int]
        let locations: [[String]]
        let groups, memberships, domains, history: [[String]]
      }
      let fingerprint = try SequenceCanonical.digest(Scope(
        version: "automatic-grouping-scope-v1", session: sessionRow[0], assets: assets,
        revisions: revisions, locations: assets.map {
          [LocationIdentity.fingerprint($0, role: .source), LocationIdentity.fingerprint($0, role: .managed)]
        }, groups: groupRows, memberships: memberships, domains: domains, history: history))
      return AutomaticGroupingInput(runID: runID, sessionID: sessionID, projectID: session.projectID,
        scopeFingerprint: fingerprint, assets: assets, assetRevisions: revisions, protectedAssetIDs: protected)
    }
  }
  func claimAutomaticGrouping(sessionID: String) throws -> AutomaticGroupingInput? {
    try transaction {
      if try automaticGroupingRun(sessionID: sessionID)?.state.succeeded == true { return nil }
      let input = try automaticGroupingSnapshot(sessionID: sessionID, runID: UUID().uuidString)
      try saveAutomaticGroupingRun(AutomaticGroupingRunRecord(
        runID: input.runID, sessionID: sessionID, scopeFingerprint: input.scopeFingerprint,
        state: .running, startedAt: Date(), finishedAt: nil, commandID: nil,
        groupIDs: [], skippedProtectedRanges: 0, message: nil, provenance: nil,
        preparedBatchFingerprint: nil))
      return input
    }
  }
  func failAutomaticGrouping(_ input: AutomaticGroupingInput, error: Error) throws {
    try transaction {
      guard var run = try automaticGroupingRun(sessionID: input.sessionID),
        run.runID == input.runID, run.state == .running else { return }
      run.state = error is CancellationError ? .cancelled : .failed
      if case LibraryError.cancelled = error { run.state = .cancelled }
      run.finishedAt = Date(); run.message = error.localizedDescription
      try saveAutomaticGroupingRun(run)
    }
  }
  func prepareAutomaticGrouping(_ analysis: AutomaticGroupingAnalysis, input: AutomaticGroupingInput,
    checkCancellation: () throws -> Void) throws -> AutomaticGroupingBatch? {
    guard analysis.runID == input.runID, analysis.scopeFingerprint == input.scopeFingerprint,
      analysis.manifest.scopeID == "automatic-grouping/" + input.sessionID,
      analysis.manifest.sessionID == input.sessionID,
      analysis.manifest.orderVersion == SequenceBaseOrder.version,
      analysis.manifest.entries.count == input.assets.count,
      analysis.featuresAvailable.count == input.assets.count,
      analysis.sourceProofs.count == input.assets.count,
      !analysis.provenance.providerVersion.isEmpty,
      SequenceCanonical.isHash(analysis.provenance.analysisSHA256)
    else { throw LibraryError.invalid("自动分组结果不属于当前完整会话") }
    for (i, asset) in input.assets.enumerated() {
      let entry = analysis.manifest.entries[i]
      guard entry.assetID == asset.id, entry.contentHash == asset.contentHash,
        entry.evidenceRevision == input.assetRevisions[i], analysis.sourceProofs[i].assetID == asset.id
      else { throw LibraryError.invalid("自动分组素材、版本或读取凭据不匹配") }
    }
    let expected = try SequenceAnalysisToken.make(manifest: analysis.manifest,
      versions: analysis.result.token.versions, policyFingerprint: analysis.result.token.policyFingerprint,
      inputRevision: analysis.result.token.inputRevision, structureRevision: analysis.result.token.structureRevision,
      generation: analysis.result.token.generation)
    try analysis.result.validate(manifest: analysis.manifest, expectedToken: expected, observations: analysis.observations)
    var groups: [AutomaticGroupingBatchGroup] = []
    var skipped = 0
    for detected in analysis.result.ranges {
      let indexes = detected.range.first...detected.range.last
      let ids = indexes.map { input.assets[$0].id }
      if !input.protectedAssetIDs.isDisjoint(with: ids) { skipped += 1; continue }
      for i in indexes {
        let proof = analysis.sourceProofs[i]
        guard analysis.featuresAvailable[i], proof.issue == nil,
          proof.verifiedSHA256 == input.assets[i].contentHash, proof.verifiedSHA256 != nil,
          proof.finalStamp != nil
        else { throw LibraryError.invalid("建议组包含未验证或不可读素材") }
      }
      groups.append(AutomaticGroupingBatchGroup(firstOrdinal: detected.range.first,
        lastOrdinal: detected.range.last, assetIDs: ids, kind: detected.kind))
    }
    let batch = AutomaticGroupingBatch(runID: input.runID, sessionID: input.sessionID,
      scopeFingerprint: input.scopeFingerprint, groups: groups, proofs: analysis.sourceProofs,
      provenance: analysis.provenance, skippedProtectedRanges: skipped)
    return try transaction {
      try checkCancellation()
      let current = try automaticGroupingSnapshot(sessionID: input.sessionID, runID: input.runID)
      guard current.scopeFingerprint == input.scopeFingerprint,
        var run = try automaticGroupingRun(sessionID: input.sessionID),
        run.runID == input.runID, run.state == .running else {
        throw LibraryError.invalid("自动分组期间会话或人工操作已改变，请稍后重试")
      }
      try validateAutomaticGroupingProofs(batch, input: current)
      run.provenance = analysis.provenance; run.skippedProtectedRanges = skipped
      if groups.isEmpty {
        run.state = .completedNoGroups; run.finishedAt = Date()
        run.message = "未新增拍摄组；已有人工组和历史操作受保护"
      } else { run.preparedBatchFingerprint = try SequenceCanonical.digest(batch) }
      try saveAutomaticGroupingRun(run)
      return groups.isEmpty ? nil : batch
    }
  }
  private func validateAutomaticGroupingProofs(_ batch: AutomaticGroupingBatch, input: AutomaticGroupingInput) throws {
    guard batch.proofs.count == input.assets.count else { throw LibraryError.invalid("读取凭据覆盖不完整") }
    let memberIDs = Set(batch.groups.flatMap(\.assetIDs))
    for (asset, proof) in zip(input.assets, batch.proofs) {
      guard proof.assetID == asset.id else { throw LibraryError.invalid("读取凭据顺序改变") }
      if memberIDs.contains(asset.id) {
        guard proof.issue == nil, let hash = proof.verifiedSHA256, hash == asset.contentHash,
          let stamp = proof.finalStamp, try AutomaticGroupingFileStamp.read(at: asset.resolvedURL) == stamp
        else { throw LibraryError.sourceChanged(asset.filename) }
      }
    }
  }
  /// Called again inside the group command transaction, before any group write.
  func validateAutomaticGroupingBatch(_ batch: AutomaticGroupingBatch) throws -> AutomaticGroupingInput {
    guard let run = try automaticGroupingRun(sessionID: batch.sessionID), run.state == .running,
      run.runID == batch.runID, run.scopeFingerprint == batch.scopeFingerprint,
      run.preparedBatchFingerprint == (try SequenceCanonical.digest(batch)), !batch.groups.isEmpty
    else { throw LibraryError.invalid("自动分组请求尚未验证、已完成或已失效") }
    let input = try automaticGroupingSnapshot(sessionID: batch.sessionID, runID: batch.runID)
    guard input.scopeFingerprint == batch.scopeFingerprint else { throw LibraryError.invalid("自动分组预览后素材或人工操作已改变") }
    var previousEnd = -1
    for group in batch.groups {
      guard group.firstOrdinal > previousEnd, group.lastOrdinal >= group.firstOrdinal,
        group.lastOrdinal < input.assets.count, group.assetIDs.count >= 2,
        group.assetIDs == (group.firstOrdinal...group.lastOrdinal).map({ input.assets[$0].id }),
        input.protectedAssetIDs.isDisjoint(with: group.assetIDs)
      else { throw LibraryError.invalid("自动分组范围重叠、越界或触及人工操作") }
      previousEnd = group.lastOrdinal
    }
    try validateAutomaticGroupingProofs(batch, input: input)
    return input
  }
  /// Runs within commitGroupCommand's transaction, after its durable undo record is written.
  func finalizeAutomaticGroupingBatch(_ batch: AutomaticGroupingBatch, command: GroupCommandRecord) throws {
    guard var run = try automaticGroupingRun(sessionID: batch.sessionID), run.state == .running,
      run.runID == batch.runID, run.preparedBatchFingerprint == (try SequenceCanonical.digest(batch))
    else { throw LibraryError.invalid("自动分组提交凭据已失效") }
    run.state = .applied; run.commandID = command.id; run.groupIDs = command.after.map(\.id)
    run.finishedAt = Date(); run.message = "已新增 \(run.groupIDs.count) 个待复核组；全部照片保留"
    try saveAutomaticGroupingRun(run)
  }
  func commitAutomaticGroupingBatch(_ batch: AutomaticGroupingBatch, checkCancellation: () throws -> Void) throws {
    try locked {
      try checkCancellation()
      let preview = try previewGroupCommand(.automaticBatch(batch))
      try checkCancellation()
      _ = try commitGroupCommand(preview)
    }
  }
}
