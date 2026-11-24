import CSQLite
import Foundation

private struct LiveDevelopmentStateCommand: Codable {
  let workID: String
  let parentVersionID: String
  let expectedRevision: Int
  let recipe: DevelopmentRecipe
  var presetAdoptions: [DevelopmentPresetAdoption]?
}

extension LibraryStore {
  func createEditingSchema() throws {
    try exec("""
      CREATE TABLE editing_works(id TEXT PRIMARY KEY, project_id TEXT NOT NULL, asset_id TEXT NOT NULL, data TEXT NOT NULL);
      CREATE TABLE editing_versions(id TEXT PRIMARY KEY, work_id TEXT NOT NULL, parent_id TEXT, data TEXT NOT NULL);
      CREATE TABLE editing_dispositions(version_id TEXT PRIMARY KEY, disposition TEXT NOT NULL);
      CREATE TABLE processing_jobs(id TEXT PRIMARY KEY, work_id TEXT NOT NULL, command_id TEXT NOT NULL UNIQUE, data TEXT NOT NULL);
      CREATE TABLE editing_commands(id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL, action TEXT NOT NULL, data TEXT NOT NULL);
      CREATE TABLE provider_profiles(id TEXT PRIMARY KEY, data TEXT NOT NULL);
      CREATE TABLE archive_publications(id TEXT PRIMARY KEY, version_id TEXT NOT NULL UNIQUE, data TEXT NOT NULL);
      CREATE TABLE editing_exports(id TEXT PRIMARY KEY, work_id TEXT NOT NULL, command_id TEXT NOT NULL UNIQUE, data TEXT NOT NULL);
      CREATE INDEX editing_works_source ON editing_works(project_id,asset_id);
      CREATE INDEX editing_versions_work ON editing_versions(work_id);
      CREATE INDEX processing_jobs_work ON processing_jobs(work_id);
      CREATE INDEX editing_exports_work ON editing_exports(work_id);
      PRAGMA user_version=7;
      """)
  }
  private func editingAdmission(assetID: String, projectID: String, sha256: String, byteCount: Int64) throws -> String {
    let sql = """
      SELECT s.asset_id,s.project_id,s.kind,printf('%!.26g',t.admitted_at),session.origin,s.scope_id,s.operation_id
      FROM lc_scopes s JOIN lc_scope_times t USING(scope_id)
      JOIN lc_contents c USING(content_id) JOIN lc_sessions session ON session.session_id=s.session_id
      WHERE s.asset_id=? AND s.project_id=? AND c.sha256=? AND c.byte_count=? AND session.state='sealed'
      ORDER BY t.admitted_at,s.scope_id LIMIT 1
      """
    guard let row = try rows(sql, [assetID,projectID,sha256,String(byteCount)]).first else { throw EditingError.staleSource }
    return try EditingFingerprint.of(ProjectAdmission(catalogRow: row))
  }
  /// Perform off-main. Hashes with bounded autorelease pools and checks inode/size/time before and after.
  public func captureEditingSourceSnapshot(assetID: String, cancel: () throws -> Void = {}) throws -> EditingSourceSnapshot {
    let original = try locked { try asset(assetID) }
    let url = original.resolvedURL
    try cancel()
    let stamp = try FileSafety.stat(url)
    let hash = try FileSafety.hash(url, cancel: cancel)
    try cancel()
    guard stamp == (try FileSafety.stat(url)) else { throw EditingError.staleSource }
    return try locked {
      let current = try asset(assetID)
      guard FileSafety.canonical(current.resolvedURL) == FileSafety.canonical(url),
        stamp == (try FileSafety.stat(current.resolvedURL)) else { throw EditingError.staleSource }
      return try editingSourceSnapshot(assetID: assetID, verifiedSHA256: hash, verifiedByteCount: stamp.size)
    }
  }
  public func editingSourceSnapshot(assetID: String, verifiedSHA256: String, verifiedByteCount: Int64) throws -> EditingSourceSnapshot {
    try locked {
      let asset = try asset(assetID)
      guard asset.id == assetID else { throw EditingError.staleSource }
      let admitted = try editingAdmission(assetID: assetID, projectID: asset.projectID, sha256: verifiedSHA256, byteCount: verifiedByteCount)
      let source = EditingSourceSnapshot(projectID: asset.projectID, assetID: asset.id,
        contentSHA256: verifiedSHA256, byteCount: verifiedByteCount,
        admissionFingerprint: admitted, sourceLocation: asset.resolvedURL,
        catalogContentHash: asset.contentHash)
      // Both reads above share the Workbench's held main-database snapshot. Standalone reads
      // can span another writer's commit and must recheck both the asset and its admission.
      let sameSnapshot = sqlite3_get_autocommit(db) == 0 && sqlite3_txn_state(db, "main") == SQLITE_TXN_READ
      try validateEditingSource(source, assetFromSnapshot: sameSnapshot ? asset : nil)
      return source
    }
  }
  func validateAdmission(_ source: EditingSourceSnapshot) throws {
    let current = try editingAdmission(assetID: source.assetID, projectID: source.projectID, sha256: source.contentSHA256, byteCount: source.byteCount)
    guard current == source.admissionFingerprint else { throw EditingError.staleSource }
  }
  /// The caller must hash actual input bytes off-main immediately before input capture/render.
  /// This guard checks current catalogue content metadata and the actual persisted admission only.
  public func validateEditingSource(_ source: EditingSourceSnapshot) throws {
    try locked { try validateEditingSource(source, assetFromSnapshot: nil) }
  }
  private func validateEditingSource(_ source: EditingSourceSnapshot, assetFromSnapshot: AssetRecord?) throws {
    guard EditingFingerprint.isSHA256(source.contentSHA256), source.byteCount > 0, source.sourceLocation.isFileURL else { throw EditingError.invalidSource }
    let asset = try assetFromSnapshot ?? self.asset(source.assetID)
    guard asset.id == source.assetID, asset.projectID == source.projectID, asset.fileSize == source.byteCount,
      asset.availability == .available, asset.contentHash.map({ $0.lowercased() == source.contentSHA256 }) ?? true,
      source.catalogContentHash.map({ $0.lowercased() == source.contentSHA256 }) ?? true else { throw EditingError.staleSource }
    if assetFromSnapshot == nil { try validateAdmission(source) }
  }
  func commandResult<T: Decodable>(id: String, fingerprint: String, action: String, type: T.Type) throws -> T? {
    guard !id.isEmpty else { throw EditingError.commandConflict }
    guard let row = try rows("SELECT fingerprint,action,data FROM editing_commands WHERE id=?", [id]).first else { return nil }
    guard row[0] == fingerprint, row[1] == action else { throw EditingError.commandConflict }
    return try decode(row[2], type)
  }
  func saveCommand<T: Encodable>(id: String, fingerprint: String, action: String, result: T) throws {
    try statement("INSERT INTO editing_commands VALUES(?,?,?,?)", [id, fingerprint, action, try json(result)])
  }
  public func createPhotoWork(source: EditingSourceSnapshot, rawDecoder: DevelopmentRAWDecoder? = nil, commandID: String = UUID().uuidString) throws -> PhotoWork {
    try transaction {
      struct InitialSource: Encodable { let source: EditingSourceSnapshot; let decoder: DevelopmentRAWDecoder }
      let fingerprint = try rawDecoder.map { try EditingFingerprint.of(InitialSource(source: source, decoder: $0)) }
        ?? EditingFingerprint.of(source)
      if let existing = try commandResult(id: commandID, fingerprint: fingerprint, action: "createWork", type: PhotoWork.self) { return existing }
      try validateEditingSource(source)
      let work = PhotoWork(source: source)
      var recipe = DevelopmentRecipe()
      if let rawDecoder {
        var adjustments = DevelopmentAdjustmentsV3()
        adjustments.rawDecoder = rawDecoder
        recipe = DevelopmentRecipe(adjustmentsV3: adjustments)
      }
      let original = EditingVersion(id: work.originalVersionID, workID: work.id, parentVersionID: nil,
                                   kind: .original, source: source, recipe: recipe, createdAt: work.createdAt)
      try statement("INSERT INTO editing_works VALUES(?,?,?,?)", [work.id, source.projectID, source.assetID, try json(work)])
      try insertVersion(original)
      try saveCommand(id: commandID, fingerprint: fingerprint, action: "createWork", result: work)
      return work
    }
  }
  public func loadPhotoWorks(projectID: String? = nil, assetID: String? = nil) throws -> [PhotoWork] {
    try locked {
      var predicates: [String] = [], values: [String] = []
      if let projectID { predicates.append("project_id=?"); values.append(projectID) }
      if let assetID { predicates.append("asset_id=?"); values.append(assetID) }
      return try rows("SELECT data FROM editing_works" + (predicates.isEmpty ? "" : " WHERE " + predicates.joined(separator: " AND ")) + " ORDER BY rowid", values).map { try decode($0[0], PhotoWork.self) }
    }
  }
  public func photoWork(id: String) throws -> PhotoWork {
    try locked {
      guard let row = try rows("SELECT data FROM editing_works WHERE id=?", [id]).first else { throw EditingError.missingWork }
      return try decode(row[0], PhotoWork.self)
    }
  }
  /// Persist the current non-destructive edit without rendering or creating an immutable candidate.
  /// The optimistic revision prevents an older asynchronous gesture from overwriting a newer one.
  public func saveLiveDevelopmentState(workID: String, recipe: DevelopmentRecipe, parentVersionID: String,
                                       expectedRevision: Int, commandID: String = UUID().uuidString, presetAdoptions: [DevelopmentPresetAdoption]? = nil) throws -> PhotoWork {
    try transaction {
      let fingerprint = try EditingFingerprint.of(LiveDevelopmentStateCommand(workID: workID,
        parentVersionID: parentVersionID, expectedRevision: expectedRevision, recipe: recipe, presetAdoptions: presetAdoptions))
      if let existing = try commandResult(id: commandID, fingerprint: fingerprint,
          action: "saveLiveDevelopment", type: PhotoWork.self) { return existing }
      var work = try photoWork(id: workID)
      let parent = try editingVersion(id: parentVersionID)
      guard parent.workID == workID, parent.source.hasSameIdentity(as: work.source),
            (work.liveRevision ?? 0) == expectedRevision else { throw EditingError.staleAdoption }
      try recipe.validate(); try validateAdmission(work.source)
      work.liveRecipe = recipe; work.liveParentVersionID = parentVersionID
      work.livePresetAdoptions = presetAdoptions
      work.liveRevision = expectedRevision + 1
      try statement("UPDATE editing_works SET data=? WHERE id=?", [try json(work), work.id])
      try saveCommand(id: commandID, fingerprint: fingerprint, action: "saveLiveDevelopment", result: work)
      return work
    }
  }
  public func loadEditingVersions(workID: String) throws -> [EditingVersion] {
    try locked { try rows("SELECT data FROM editing_versions WHERE work_id=? ORDER BY rowid", [workID]).map { try decode($0[0], EditingVersion.self) } }
  }
  public func editingVersion(id: String) throws -> EditingVersion {
    try locked {
      guard let row = try rows("SELECT data FROM editing_versions WHERE id=?", [id]).first else { throw EditingError.missingVersion }
      return try decode(row[0], EditingVersion.self)
    }
  }
  private func validateVersion(_ version: EditingVersion, work: PhotoWork) throws {
    try EditingArchive.safeID(version.id); try EditingArchive.safeID(version.workID)
    try version.recipe.validate(); try validateConfiguration(version.configuration)
    guard version.workID == work.id, version.source.hasSameIdentity(as: work.source),
      version.kind != .original, let parentID = version.parentVersionID, parentID != version.id else { throw EditingError.invalidParent }
    let parent = try editingVersion(id: parentID)
    guard parent.workID == work.id, parent.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidParent }
    // Parent must already exist and version ID must be new, so a cycle cannot be introduced.
    if let artifact = version.artifact { try artifact.validate() }
    if version.kind == .ai || version.kind == .external { guard version.artifact != nil else { throw EditingError.invalidArtifact } }
  }
  private func insertVersion(_ version: EditingVersion) throws {
    try statement("INSERT INTO editing_versions VALUES(?,?,?,?)", [version.id, version.workID, version.parentVersionID ?? "", try json(version)])
    try statement("INSERT INTO editing_dispositions VALUES(?,?)", [version.id, VersionDisposition.candidate.rawValue])
  }
  public func appendEditingVersion(_ version: EditingVersion, commandID: String = UUID().uuidString) throws -> EditingVersion {
    try transaction {
      let fingerprint = try EditingFingerprint.of(version)
      if let existing = try commandResult(id: commandID, fingerprint: fingerprint, action: "appendVersion", type: EditingVersion.self) { return existing }
      guard version.artifact == nil, version.kind == .development else { throw EditingError.invalidArtifact }
      let work = try photoWork(id: version.workID)
      try validateEditingSource(version.source); try validateVersion(version, work: work)
      try insertVersion(version)
      try saveCommand(id: commandID, fingerprint: fingerprint, action: "appendVersion", result: version)
      return version
    }
  }
  public func adoptEditingVersion(workID: String, versionID: String, expectedRevision: Int, commandID: String = UUID().uuidString) throws -> PhotoWork {
    try transaction {
      let fingerprint = try EditingFingerprint.of(["workID": workID, "versionID": versionID, "expectedRevision": String(expectedRevision)])
      if let existing = try commandResult(id: commandID, fingerprint: fingerprint, action: "adoptVersion", type: PhotoWork.self) { return existing }
      var work = try photoWork(id: workID)
      let version = try editingVersion(id: versionID)
      guard version.workID == workID else { throw EditingError.invalidParent }
      guard work.adoptionRevision == expectedRevision else { throw EditingError.staleAdoption }
      if work.strictDocumentary == true && version.kind == .ai { throw EditingError.strictDocumentary }
      try validateAdmission(work.source)
      if version.artifact == nil { try validateEditingSource(version.source) }
      else {
        let publication = try publicationForVersion(version.id)
        try editingArchive().validate(publication)
        if let jobID = publication.jobID, let request = try processingJob(id: jobID).request.quickPrompt {
          let job = try processingJob(id: jobID), parent = try editingVersion(id: job.request.inputVersionID)
          guard job.attempts.contains(where: { $0.resultVersionID == versionID }),
            try versionDisposition(versionID: versionID) != .discarded,
            request.matches(work, parent: parent, recipe: job.request.recipe) else { throw EditingError.staleAdoption }
        }
      }
      work.adoptedVersionID = versionID; work.adoptionRevision += 1
      try statement("UPDATE editing_works SET data=? WHERE id=?", [try json(work), work.id])
      try statement("UPDATE editing_dispositions SET disposition=? WHERE version_id=?", [VersionDisposition.retained.rawValue, versionID])
      try saveCommand(id: commandID, fingerprint: fingerprint, action: "adoptVersion", result: work)
      return work
    }
  }

  public func setStrictDocumentary(workID: String, enabled: Bool) throws -> PhotoWork {
    try transaction {
      var work = try photoWork(id: workID)
      if enabled, try editingVersion(id: work.adoptedVersionID).kind == .ai { throw EditingError.strictDocumentary }
      if enabled, try loadProcessingJobs(workID: workID).contains(where: {
        !$0.state.isTerminal && $0.state != .outcomeUnknown && $0.currentAttempt.submissionIntentAt != nil
      }) { throw EditingError.illegalTransition }
      work.strictDocumentary = enabled
      try statement("UPDATE editing_works SET data=? WHERE id=?", [try json(work), work.id])
      return work
    }
  }

  public func undoQuickPromptAdoption(workID: String, versionID: String, expectedRevision: Int) throws -> PhotoWork {
    try transaction {
      var work = try photoWork(id: workID)
      guard work.adoptedVersionID == versionID, work.adoptionRevision == expectedRevision,
            let jobID = try publicationForVersion(versionID).jobID else { throw EditingError.staleAdoption }
      let job = try processingJob(id: jobID)
      guard let previous = job.request.quickPrompt, previous.adoptionRevision == expectedRevision - 1,
            try editingVersion(id: previous.adoptedVersionID).workID == workID else { throw EditingError.staleAdoption }
      work.adoptedVersionID = previous.adoptedVersionID; work.adoptionRevision += 1
      try statement("UPDATE editing_works SET data=? WHERE id=?", [try json(work), work.id])
      return work
    }
  }
  public func versionDisposition(versionID: String) throws -> VersionDisposition {
    try locked {
      guard let row = try rows("SELECT disposition FROM editing_dispositions WHERE version_id=?", [versionID]).first,
        let value = VersionDisposition(rawValue: row[0]) else { throw EditingError.missingVersion }
      return value
    }
  }
  public func setVersionDisposition(versionID: String, disposition: VersionDisposition) throws {
    try transaction {
      let version = try editingVersion(id: versionID), work = try photoWork(id: version.workID)
      if disposition == .discarded {
        guard version.id != work.adoptedVersionID, version.id != work.originalVersionID,
          try rows("SELECT id FROM editing_versions WHERE work_id=? AND parent_id=? LIMIT 1", [work.id, versionID]).isEmpty,
          try loadProcessingJobs(workID: work.id).allSatisfy({ $0.request.inputVersionID != versionID }) else { throw EditingError.invalidParent }
      }
      try statement("UPDATE editing_dispositions SET disposition=? WHERE version_id=?", [disposition.rawValue, versionID])
    }
  }
  private func validateConfiguration(_ configuration: [String: String]) throws {
    let forbidden: Set<String> = ["apikey", "authorization", "token", "accesstoken", "refreshtoken", "secret", "password", "clientsecret"]
    guard configuration.keys.allSatisfy({ !forbidden.contains($0.lowercased().filter { $0.isLetter || $0.isNumber }) }) else { throw EditingError.invalidProfile }
  }
  private func validateProfile(_ profile: AIProviderProfile) throws {
    try validateConfiguration(profile.configuration)
    let endpoint = profile.endpoint
    guard !profile.id.isEmpty, !profile.model.isEmpty, !profile.capabilities.capabilityID.isEmpty,
      let components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
      components.user == nil, components.password == nil, components.query == nil, components.fragment == nil,
      let host = components.host, !host.isEmpty,
      components.scheme == "https" || (profile.kind == .localComfy && components.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)),
      profile.capabilities.maxInputPixels.map({ $0 > 0 }) ?? true,
      !profile.capabilities.supportedOutputEncodings.isEmpty else { throw EditingError.invalidProfile }
    if profile.kind == .localComfy {
      guard ["localhost", "127.0.0.1", "::1"].contains(host) else { throw EditingError.invalidProfile }
    }
  }
  public func saveProviderProfile(_ profile: AIProviderProfile) throws {
    try transaction {
      try validateProfile(profile)
      try statement("INSERT INTO provider_profiles VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data", [profile.id, try json(profile)])
    }
  }
  public func loadProviderProfiles() throws -> [AIProviderProfile] {
    try locked { try rows("SELECT data FROM provider_profiles ORDER BY rowid").map { try decode($0[0], AIProviderProfile.self) } }
  }
  public func enqueueProcessingJob(commandID: String, request: AIEditRequest) throws -> ProcessingJob {
    try transaction {
      let fingerprint = try request.fingerprint
      if let existing = try commandResult(id: commandID, fingerprint: fingerprint, action: "enqueueJob", type: ProcessingJob.self) { return try processingJob(id: existing.id) }
      try validateProfile(request.profile); try validateConfiguration(request.configuration)
      try request.recipe.validate(); try request.inputArtifact.validate()
      guard request.profile.acceptedForUse, request.inputFileURL.isFileURL else { throw EditingError.invalidProfile }
      let work = try photoWork(id: request.workID), input = try editingVersion(id: request.inputVersionID)
      guard input.workID == work.id, request.source.hasSameIdentity(as: work.source) else { throw EditingError.invalidParent }
      if work.strictDocumentary == true { throw EditingError.strictDocumentary }
      if let quick = request.quickPrompt {
        try quick.validate(input: request.inputArtifact)
        guard quick.matches(work, parent: input, recipe: request.recipe),
          try loadProcessingJobs(workID: work.id).allSatisfy({ !$0.blocksQuickPromptSubmission }) else {
          throw EditingError.staleAdoption
        }
      } else if input.recipe != request.recipe { throw EditingError.invalidParent }
      try validateEditingSource(request.source)
      if let limit = request.profile.capabilities.maxInputPixels {
        guard request.inputArtifact.pixelWidth <= limit / request.inputArtifact.pixelHeight else { throw EditingError.invalidArtifact }
      }
      let archive = try editingArchive()
      var frozenRequest = request
      frozenRequest.inputArtifact = try archive.freezeProcessingInput(fileURL: request.inputFileURL, artifact: request.inputArtifact, commandID: commandID, fingerprint: fingerprint)
      frozenRequest.inputFileURL = try archive.processingInputURL(frozenRequest.inputArtifact)
      if var quick = request.quickPrompt {
        func freeze(_ file: QuickPromptInputFile, role: String) throws -> QuickPromptInputFile {
          let artifact = try archive.freezeProcessingInput(fileURL: file.url, artifact: file.artifact,
            commandID: commandID + "." + role, fingerprint: fingerprint)
          return try QuickPromptInputFile(artifact: artifact, url: archive.processingInputURL(artifact))
        }
        quick.basis = try freeze(quick.basis, role: "basis")
        quick.matte = try quick.matte.map { try freeze($0, role: "matte") }
        frozenRequest.quickPrompt = quick
      }
      let job = ProcessingJob(commandID: commandID, requestFingerprint: fingerprint, request: frozenRequest)
      try statement("INSERT INTO processing_jobs VALUES(?,?,?,?)", [job.id, work.id, commandID, try json(job)])
      try saveCommand(id: commandID, fingerprint: fingerprint, action: "enqueueJob", result: job)
      return job
    }
  }
  public func processingJob(id: String) throws -> ProcessingJob {
    try locked {
      guard let row = try rows("SELECT data FROM processing_jobs WHERE id=?", [id]).first else { throw EditingError.missingJob }
      return try resolveProcessingJobInput(decode(row[0], ProcessingJob.self))
    }
  }
  private func resolveProcessingJobInput(_ value: ProcessingJob) throws -> ProcessingJob {
    var job = value
    guard !job.attempts.isEmpty else { throw EditingError.missingJob }
    if job.request.inputArtifact.relativePath.hasPrefix(".inputs/") {
      _ = try FileSafety.safeRelative(job.request.inputArtifact.relativePath)
      guard let root = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first else { throw EditingError.archiveNotConfigured }
      let archiveRoot = URL(fileURLWithPath: root)
      let url = archiveRoot.appendingPathComponent(job.request.inputArtifact.relativePath)
      guard FileSafety.contains(archiveRoot, url) else { throw EditingError.unsafePath }
      job.request.inputFileURL = url
      if var quick = job.request.quickPrompt {
        func resolve(_ file: QuickPromptInputFile) throws -> QuickPromptInputFile {
          let relative = file.artifact.relativePath
          _ = try FileSafety.safeRelative(relative)
          let url = archiveRoot.appendingPathComponent(relative)
          guard relative.hasPrefix(".inputs/"), FileSafety.contains(archiveRoot, url) else { throw EditingError.unsafePath }
          return QuickPromptInputFile(artifact: file.artifact, url: url)
        }
        quick.basis = try resolve(quick.basis)
        quick.matte = try quick.matte.map(resolve)
        job.request.quickPrompt = quick
      }
    }
    return job
  }
  public func loadProcessingJobs(workID: String? = nil) throws -> [ProcessingJob] {
    try locked { try rows("SELECT data FROM processing_jobs" + (workID == nil ? "" : " WHERE work_id=?") + " ORDER BY rowid", workID.map { [$0] } ?? []).map { try resolveProcessingJobInput(decode($0[0], ProcessingJob.self)) } }
  }
  private func writeJob(_ job: ProcessingJob) throws {
    try statement("UPDATE processing_jobs SET data=? WHERE id=?", [try json(job), job.id])
  }
  public func acknowledgeQuickPromptOutcome(id: String, attemptID: String) throws {
    try locked {
      let archive = try editingArchive()
      for received in try archive.recoverReceivedOutputs() where received.jobID == id { try commitReceivedOutput(received) }
      for publication in try archive.recoverPublications() where publication.jobID == id { _ = try commitArchivePublication(publication) }
      try transaction {
        var job = try processingJob(id: id)
        let attempt = job.currentAttempt
        guard job.request.quickPrompt != nil, attempt.id == attemptID, job.state == .outcomeUnknown,
              attempt.workerJoined || job.request.profile.kind != .localComfy,
              attempt.receivedOutput == nil, attempt.pendingReceivedOutput == nil else { throw EditingError.illegalTransition }
        job.acknowledgedQuickPromptOutcomeAt = job.acknowledgedQuickPromptOutcomeAt ?? Date()
        try writeJob(job)
      }
    }
  }
  public func transitionProcessingJob(id: String, attemptID: String, runID: String, to next: ProcessingJobState,
    remoteID: String? = nil, workerJoined: Bool = false, error: String? = nil) throws -> ProcessingJob {
    try transaction {
      var job = try processingJob(id: id), attempt = job.currentAttempt
      guard attempt.id == attemptID, attempt.runID == runID else { throw EditingError.staleAttempt }
      // A terminal failure can precede native worker joining. Permit only an identity-guarded
      // join acknowledgement, never a terminal-state rewrite or another submission.
      if attempt.state.isTerminal {
        guard next == attempt.state, workerJoined, remoteID == nil || remoteID == attempt.remoteID, error == nil else { throw EditingError.illegalTransition }
        attempt.workerJoined = true; attempt.updatedAt = Date(); job.attempts[job.attempts.count - 1] = attempt
        try writeJob(job); return job
      }
      guard job.resultVersionID == nil else { throw EditingError.illegalTransition }
      let legal: [ProcessingJobState: Set<ProcessingJobState>] = [
        .queued: [.preparing, .cancelRequested, .cancelled, .failed],
        .preparing: [.submitting, .cancelRequested, .cancelled, .failed],
        .submitting: [.running, .archiving, .cancelRequested, .outcomeUnknown, .failed],
        .running: [.archiving, .cancelRequested, .outcomeUnknown, .failed],
        .archiving: [.cancelRequested, .outcomeUnknown, .failed],
        .cancelRequested: [.cancelled, .archiving, .outcomeUnknown, .failed],
        .outcomeUnknown: [.reconciling],
        .reconciling: [.running, .archiving, .outcomeUnknown, .failed, .cancelRequested, .cancelled]
      ]
      guard next != .succeeded, !attempt.state.isTerminal,
        next == attempt.state || legal[attempt.state, default: []].contains(next) else { throw EditingError.illegalTransition }
      if next == .submitting {
        if try photoWork(id: job.request.workID).strictDocumentary == true { throw EditingError.strictDocumentary }
        try validateEditingSource(job.request.source)
        if attempt.submissionIntentAt == nil { attempt.submissionIntentAt = Date() }
        if job.request.quickPrompt != nil && job.request.profile.kind != .localComfy { job.usageState = .pendingReconciliation }
      }
      if next == .running || next == .archiving { guard attempt.submissionIntentAt != nil else { throw EditingError.illegalTransition } }
      if next == .cancelled { guard workerJoined || attempt.workerJoined else { throw EditingError.workerNotJoined } }
      if let remoteID {
        guard attempt.remoteID == nil || attempt.remoteID == remoteID else { throw EditingError.staleAttempt }
        attempt.remoteID = remoteID
      }
      attempt.state = next; attempt.workerJoined = attempt.workerJoined || workerJoined
      attempt.error = error; attempt.updatedAt = Date(); job.attempts[job.attempts.count - 1] = attempt
      try writeJob(job); return job
    }
  }
  public func retryProcessingJob(id: String, allowUnknownOutcome: Bool = false) throws -> ProcessingJob {
    try locked {
      // A result receipt may have survived even when the DB callback did not. Resolve it before authorizing any resubmission.
      let archive = try editingArchive()
      for received in try archive.recoverReceivedOutputs() where received.jobID == id { try commitReceivedOutput(received) }
      for publication in try archive.recoverPublications() where publication.jobID == id { _ = try commitArchivePublication(publication) }
      return try transaction {
        var job = try processingJob(id: id)
        guard job.resultVersionID == nil, job.request.quickPrompt == nil else { throw EditingError.illegalTransition }
        let old = job.currentAttempt
        guard old.receivedOutput == nil, old.pendingReceivedOutput == nil else { throw EditingError.outputAlreadyReceived }
        guard old.state == .failed || old.state == .cancelled || old.state == .outcomeUnknown else { throw EditingError.illegalTransition }
        guard old.workerJoined else { throw EditingError.workerNotJoined }
        if old.state == .outcomeUnknown && !allowUnknownOutcome { throw EditingError.outcomeUnknown }
        try validateEditingSource(job.request.source)
        job.attempts.append(.init(number: old.number + 1)); try writeJob(job); return job
      }
    }
  }
  /// Call immediately after provider returns and before archive publication. Run off-main.
  /// Returned bytes become immutable archive-owned input for retrying publication without network I/O.
  public func recordProcessingOutput(id: String, attemptID: String, runID: String, output: AIEditOutput) throws -> AIEditOutput {
    try locked {
      let job = try processingJob(id: id)
      guard let index = job.attempts.firstIndex(where: { $0.id == attemptID && $0.runID == runID }),
        job.attempts[index].submissionIntentAt != nil else { throw EditingError.staleAttempt }
      try validateConfiguration(output.configuration)
      if let remoteID = output.remoteID {
        guard job.attempts[index].remoteID == nil || job.attempts[index].remoteID == remoteID else { throw EditingError.staleAttempt }
      }
      let archive = try editingArchive()
      if let received = job.attempts[index].receivedOutput {
        var expectedArtifact = output.artifact; expectedArtifact.relativePath = received.artifact.relativePath
        guard received.artifact == expectedArtifact,
          received.configuration == output.configuration, received.remoteID == output.remoteID else { throw EditingError.commandConflict }
        return try archive.resolveReceivedOutput(received)
      }
      // Record returned-result intent before any disk-heavy copying. A capture failure may never become a paid resubmission.
      try transaction {
        var current = try processingJob(id: id)
        guard let currentIndex = current.attempts.firstIndex(where: { $0.id == attemptID && $0.runID == runID }) else { throw EditingError.staleAttempt }
        if let pending = current.attempts[currentIndex].pendingReceivedOutput {
          guard pending.artifact == output.artifact, pending.configuration == output.configuration, pending.remoteID == output.remoteID else { throw EditingError.commandConflict }
        } else {
          try output.artifact.validate()
          var pending = output; pending.fileURL = FileSafety.canonical(output.fileURL)
          current.attempts[currentIndex].pendingReceivedOutput = pending
          if current.attempts[currentIndex].resultVersionID == nil { current.attempts[currentIndex].state = .archiving }
          current.attempts[currentIndex].workerJoined = true; current.attempts[currentIndex].updatedAt = Date()
          try writeJob(current)
        }
      }
      // Recover a receipt left by a previous callback/DB failure before creating any duplicate bytes.
      let existing = try archive.recoverReceivedOutputs().filter { $0.jobID == id && $0.attemptID == attemptID && $0.runID == runID }
      if let received = existing.first {
        guard existing.count == 1, received.artifact.sha256 == output.artifact.sha256,
          received.configuration == output.configuration, received.remoteID == output.remoteID else { throw EditingError.commandConflict }
        try commitReceivedOutput(received)
        return try archive.resolveReceivedOutput(received)
      }
      let received = try archive.receive(output: output, jobID: id, attemptID: attemptID, runID: runID)
      try commitReceivedOutput(received)
      return try archive.resolveReceivedOutput(received)
    }
  }
  public func receivedProcessingOutput(id: String, attemptID: String? = nil) throws -> AIEditOutput? {
    try locked {
      let job = try processingJob(id: id)
      let attempt: ProcessingAttempt
      if let attemptID {
        guard let found = job.attempts.first(where: { $0.id == attemptID }) else { throw EditingError.staleAttempt }
        attempt = found
      } else { attempt = job.currentAttempt }
      if let received = attempt.receivedOutput { return try editingArchive().resolveReceivedOutput(received) }
      if let pending = attempt.pendingReceivedOutput {
        return try recordProcessingOutput(id: id, attemptID: attempt.id, runID: attempt.runID, output: pending)
      }
      return nil
    }
  }
  private func commitReceivedOutput(_ received: ReceivedProcessingOutput) throws {
    try transaction {
      _ = try editingArchive().resolveReceivedOutput(received)
      var job = try processingJob(id: received.jobID)
      guard let index = job.attempts.firstIndex(where: { $0.id == received.attemptID && $0.runID == received.runID }),
        job.attempts[index].submissionIntentAt != nil else { throw EditingError.staleAttempt }
      try validateConfiguration(received.configuration)
      if let old = job.attempts[index].receivedOutput {
        guard old == received else { throw EditingError.commandConflict }; return
      }
      if let remoteID = received.remoteID {
        guard job.attempts[index].remoteID == nil || job.attempts[index].remoteID == remoteID else { throw EditingError.staleAttempt }
        job.attempts[index].remoteID = remoteID
      }
      job.attempts[index].receivedOutput = received
      job.attempts[index].pendingReceivedOutput = nil
      if job.request.quickPrompt != nil && job.request.profile.kind != .localComfy {
        job.usageState = received.configuration["usage"] == "reported" ? .confirmed : .unknown
      }
      // Receiving a completed file is independent of cancellation intent and confirms the provider call returned.
      // Preserve completed-result state; otherwise the only remaining action is local archiving.
      if job.attempts[index].resultVersionID == nil { job.attempts[index].state = .archiving }
      job.attempts[index].workerJoined = true; job.attempts[index].updatedAt = Date()
      try writeJob(job)
    }
  }
  private func protectedEditingRoots() throws -> [URL] { try editingProtectedRoots() }
  public func configureEditingArchive(root: URL) throws -> EditingArchive {
    try transaction {
      let existing = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first
      if let existing {
        guard FileSafety.canonical(URL(fileURLWithPath: existing)).path == FileSafety.canonical(root).path else { throw EditingError.archiveMismatch }
      }
      let archive = try EditingArchive(root: root, protectedRoots: protectedEditingRoots())
      if existing == nil { try statement("INSERT INTO metadata VALUES('editingArchiveRoot',?)", [archive.root.path]) }
      return archive
    }
  }
  public func editingArchive() throws -> EditingArchive {
    try locked {
      guard let root = try rows("SELECT value FROM metadata WHERE key='editingArchiveRoot'").first?.first else { throw EditingError.archiveNotConfigured }
      return try EditingArchive(root: URL(fileURLWithPath: root), protectedRoots: protectedEditingRoots())
    }
  }
  private func publicationForVersion(_ versionID: String) throws -> ArchivePublicationReceipt {
    guard let row = try rows("SELECT data FROM archive_publications WHERE version_id=?", [versionID]).first else { throw EditingError.archiveMismatch }
    return try decode(row[0], ArchivePublicationReceipt.self)
  }
  /// Recoverable completion may append an historical candidate after cancellation/source changes.
  /// It never overwrites a version, request, adoption pointer or original asset.
  public func commitArchivePublication(_ receipt: ArchivePublicationReceipt) throws -> EditingVersion {
    try transaction {
      try editingArchive().validate(receipt)
      if let row = try rows("SELECT data FROM archive_publications WHERE id=?", [receipt.id]).first {
        let existing = try decode(row[0], ArchivePublicationReceipt.self)
        guard existing == receipt else { throw EditingError.commandConflict }
        return existing.version
      }
      let version = receipt.version, work = try photoWork(id: receipt.version.workID)
      try validateVersion(version, work: work)
      if let jobID = receipt.jobID {
        var job = try processingJob(id: jobID)
        guard job.request.workID == work.id, job.request.inputVersionID == version.parentVersionID,
          version.kind == .ai, version.recipe == job.request.recipe, let index = job.attempts.firstIndex(where: { $0.id == receipt.attemptID && $0.runID == receipt.runID }),
          job.attempts[index].submissionIntentAt != nil else { throw EditingError.staleAttempt }
        guard job.attempts[index].resultVersionID == nil else { throw EditingError.staleAttempt }
        if let quick = job.request.quickPrompt {
          guard let received = job.attempts[index].receivedOutput, let artifact = version.artifact,
            version.configuration["quickPromptRawOutputSHA256"] == received.artifact.sha256,
            version.configuration["quickPromptBasisSHA256"] == quick.basis.artifact.sha256,
            ["public.png", "image/png"].contains(received.artifact.encoding), received.artifact.bitDepth == 8,
            received.artifact.pixelWidth == job.request.inputArtifact.pixelWidth,
            received.artifact.pixelHeight == job.request.inputArtifact.pixelHeight else { throw EditingError.archiveMismatch }
          if quick.selection == nil {
            guard artifact.sha256 == received.artifact.sha256, artifact.byteCount == received.artifact.byteCount else { throw EditingError.archiveMismatch }
          } else {
            guard artifact.pixelWidth == quick.basis.artifact.pixelWidth, artifact.pixelHeight == quick.basis.artifact.pixelHeight,
              artifact.bitDepth == 16, artifact.encoding == "public.tiff" else { throw EditingError.archiveMismatch }
          }
        } else if let received = job.attempts[index].receivedOutput {
          guard let artifact = version.artifact, artifact.sha256 == received.artifact.sha256,
            artifact.byteCount == received.artifact.byteCount else { throw EditingError.archiveMismatch }
        }
        // An older explicitly retried run can complete late. Preserve its candidate and attempt receipt,
        // but never replace the active attempt's state or completed result pointer.
        if index == job.attempts.count - 1 {
          guard job.resultVersionID == nil else { throw EditingError.staleAttempt }
          job.resultVersionID = version.id
        }
        job.attempts[index].resultVersionID = version.id
        job.attempts[index].state = .succeeded; job.attempts[index].updatedAt = Date()
        try writeJob(job)
      } else { guard version.kind != .ai else { throw EditingError.missingJob } }
      try insertVersion(version)
      try statement("INSERT INTO archive_publications VALUES(?,?,?)", [receipt.id, version.id, try json(receipt)])
      return version
    }
  }
  public func recoverEditingArchive() throws -> [ArchivePublicationReceipt] {
    let archive = try editingArchive()
    for received in try archive.recoverReceivedOutputs() { try commitReceivedOutput(received) }
    for job in try loadProcessingJobs() {
      for attempt in job.attempts where attempt.receivedOutput == nil {
        if let pending = attempt.pendingReceivedOutput {
          _ = try recordProcessingOutput(id: job.id, attemptID: attempt.id, runID: attempt.runID, output: pending)
        }
      }
    }
    let receipts = try archive.recoverPublications()
    for receipt in receipts { _ = try commitArchivePublication(receipt) }
    return receipts
  }
}
