import Foundation

extension LibraryStore {
  func createProjectReviewSchema() throws {
    for (table, key) in [("review_records", "asset_id"), ("project_review_states", "project_id"), ("tag_commands", "id"), ("tag_domains", "asset_id")] {
      try exec("CREATE TABLE \(table)(\(key) TEXT PRIMARY KEY, data TEXT NOT NULL)")
    }
    // Seed domains only. Existing tag arrays and decisions are never rewritten by migration.
    for row in try rows("SELECT asset_id FROM asset_tags") {
      try statement("INSERT INTO tag_domains VALUES(?,?)", [row[0], try json(TagDomain())])
    }
    try exec("PRAGMA user_version=5")
  }

  public func loadReviewRecords(projectID: String? = nil) throws -> [ReviewRecord] {
    try locked {
      try rows("SELECT data FROM review_records ORDER BY rowid").map { try decode($0[0], ReviewRecord.self) }.filter { projectID == nil || $0.projectID == projectID }
    }
  }
  func assertAdmitted(_ ids: [String]) throws -> [AssetRecord] {
    let admitted = Dictionary(uniqueKeysWithValues: try loadAdmissions().map { ($0.assetID, $0.projectID) })
    return try Array(Set(ids)).sorted().map { id in
      let a = try asset(id)
      guard admitted[id] == a.projectID else { throw LibraryError.invalid("操作只支持已纳入项目的素材") }
      return a
    }
  }
  func writeReview(_ assets: [AssetRecord], reviewed: Bool) throws {
    for a in assets {
      let record = ReviewRecord(assetID: a.id, projectID: a.projectID, reviewed: reviewed)
      try statement("INSERT INTO review_records VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data", [a.id, try json(record)])
    }
  }
  public func markReviewed(ids: [String], reviewed: Bool) throws {
    try transaction {
      let assets = try assertAdmitted(ids)
      try writeReview(assets, reviewed: reviewed)
      if !assets.isEmpty { try operation(entity: "project-review", action: reviewed ? "markReviewed" : "markUnreviewed", payload: try json(assets.map(\.id))) }
    }
  }
  public func loadProjectReviewState(projectID: String) throws -> ProjectReviewState? {
    try locked {
      guard let row = try rows("SELECT data FROM project_review_states WHERE project_id=?", [projectID]).first else { return nil }
      return try decode(row[0], ProjectReviewState.self)
    }
  }
  @discardableResult public func saveProjectReviewState(_ state: ProjectReviewState) throws -> ProjectReviewState {
    try transaction {
      guard try publishedProjects().contains(where: { $0.id == state.projectID }) else { throw LibraryError.invalid("项目不可用") }
      try state.query.validate()
      guard ["grid", "single", "compare"].contains(state.mode), state.selectedAssetIDs.count <= 30_000 else { throw LibraryError.invalid("项目浏览状态无效") }
      let current = try loadProjectReviewState(projectID: state.projectID)
      guard state.revision == (current?.revision ?? 0) else { throw LibraryError.invalid("项目浏览状态已由其他窗口修改，请重新载入") }
      let admitted = Set(try loadAdmissions().filter { $0.projectID == state.projectID }.map(\.assetID))
      var next = state
      next.focusedAssetID = state.focusedAssetID.flatMap { admitted.contains($0) ? $0 : nil }
      next.selectedAssetIDs = Array(Set(state.selectedAssetIDs)).filter { admitted.contains($0) }.sorted()
      let pairIDs = Set(try loadCapturePairs().filter { Set($0.assetIDs).isSubset(of: admitted) }.map(\.id))
      next.expandedPairIDs = Array(Set(state.expandedPairIDs).intersection(pairIDs)).sorted()
      next.rawPreviewPairIDs = Array(Set(state.rawPreviewPairIDs).intersection(pairIDs)).sorted()
      next.revision += 1
      try statement("INSERT INTO project_review_states VALUES(?,?) ON CONFLICT(project_id) DO UPDATE SET data=excluded.data", [state.projectID, try json(next)])
      return next
    }
  }
  public func reviewProgress(projectID: String) throws -> ReviewProgress {
    try locked {
      let admissions = try loadAdmissions().filter { $0.projectID == projectID }
      let ids = Set(admissions.map(\.assetID))
      let reviewed = Set(try loadReviewRecords(projectID: projectID).filter(\.reviewed).map(\.assetID)).intersection(ids)
      return ReviewProgress.calculate(assetIDs: ids, reviewedIDs: reviewed, pairs: try loadCapturePairs(), sequenceOnlyIDs: Set(admissions.filter(\.sequenceOnly).map(\.assetID)))
    }
  }
  public func searchAssets(query: ProjectSearchQuery, projectID: String? = nil, sort: ProjectReviewSort = .original) throws -> [AssetRecord] {
    try locked {
      let admitted = Set(try loadAdmissions().filter { projectID == nil || $0.projectID == projectID }.map(\.assetID))
      return try AssetSearchEngine.filter(assets: loadAssets().filter { admitted.contains($0.id) }, query: query, tags: loadTags(), reviewedIDs: Set(loadReviewRecords().filter(\.reviewed).map(\.assetID)), sort: sort, colorLabels: loadColorLabels())
    }
  }
  public func tagVocabulary(prefix: String = "") throws -> [String] {
    try locked {
      let admitted = Set(try loadAdmissions().map(\.assetID))
      let wanted = TagText.key(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
      var seen = Set<String>(), values: [String] = []
      for (id, tags) in try loadTags().sorted(by: { $0.key < $1.key }) where admitted.contains(id) {
        for tag in tags {
          let key = TagText.key(tag)
          if (wanted.isEmpty || key.hasPrefix(wanted)) && seen.insert(key).inserted { values.append(tag) }
        }
      }
      return values.sorted()
    }
  }
  func tagDomain(_ id: String) throws -> TagDomain {
    try rows("SELECT data FROM tag_domains WHERE asset_id=?", [id]).first.map { try decode($0[0], TagDomain.self) } ?? TagDomain()
  }
  func writeTags(_ id: String, tags: [String], domain: TagDomain) throws {
    try statement("INSERT INTO asset_tags VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data", [id, try json(tags)])
    try statement("INSERT INTO tag_domains VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data", [id, try json(domain)])
  }
  public func previewTagMutation(ids: [String], mode: TagMutationMode = .add, tags: [String]) throws -> TagMutationPreview {
    try locked {
      let assets = try assertAdmitted(ids)
      guard !assets.isEmpty else { throw LibraryError.invalid("请选择要修改标签的项目素材") }
      let input = try TagText.normalized(tags), wanted = Set(input.map(TagText.key)), existing = try loadTags()
      var before: [String: [String]] = [:], after: [String: [String]] = [:], domains: [String: TagDomain] = [:]
      for a in assets {
        let old = existing[a.id] ?? []
        before[a.id] = old; domains[a.id] = try tagDomain(a.id)
        switch mode {
        case .add:
          let keys = Set(old.map(TagText.key))
          after[a.id] = old + input.filter { !keys.contains(TagText.key($0)) }
        case .remove: after[a.id] = old.filter { !wanted.contains(TagText.key($0)) }
        case .replace: after[a.id] = input
        }
        guard after[a.id]!.count <= 100 else { throw LibraryError.invalid("操作后标签数量超限") }
      }
      let allKeys = assets.map { Set((before[$0.id] ?? []).map(TagText.key)) }
      let common = allKeys.dropFirst().reduce(allKeys.first ?? []) { $0.intersection($1) }
      let union = allKeys.reduce(Set<String>()) { $0.union($1) }
      var display: [String: String] = [:]
      for a in assets { for tag in before[a.id] ?? [] where display[TagText.key(tag)] == nil { display[TagText.key(tag)] = tag } }
      return TagMutationPreview(id: UUID().uuidString, mode: mode, tags: input, assetIDs: assets.map(\.id), before: before, after: after,
                                domains: domains, commonTags: common.compactMap { display[$0] }.sorted(), mixedTags: union.subtracting(common).compactMap { display[$0] }.sorted())
    }
  }
  @discardableResult public func commitTagMutation(_ preview: TagMutationPreview) throws -> TagCommand {
    try transaction {
      if let row = try rows("SELECT data FROM tag_commands WHERE id=?", [preview.id]).first {
        let existing = try decode(row[0], TagCommand.self)
        guard try stableJSON(existing.preview) == stableJSON(preview) else { throw LibraryError.invalid("重复标签请求内容不同") }
        return existing
      }
      let fresh = try previewTagMutation(ids: preview.assetIDs, mode: preview.mode, tags: preview.tags)
      guard fresh.assetIDs == preview.assetIDs, fresh.before == preview.before, fresh.after == preview.after, fresh.domains == preview.domains,
            fresh.commonTags == preview.commonTags, fresh.mixedTags == preview.mixedTags else { throw LibraryError.invalid("标签或成员已变化，请重新预览") }
      let command = TagCommand(preview: preview, restored: false, createdAt: Date())
      for id in preview.changedAssetIDs {
        let old = try tagDomain(id)
        try writeTags(id, tags: preview.after[id]!, domain: TagDomain(revision: old.revision + 1, logicalWriterID: preview.id))
      }
      try statement("INSERT INTO tag_commands VALUES(?,?)", [command.id, try json(command)])
      if !preview.changedAssetIDs.isEmpty { try operation(entity: command.id, action: "tagMutation", payload: try json(command)) }
      return command
    }
  }
  public func loadTagCommands() throws -> [TagCommand] {
    try locked { try rows("SELECT data FROM tag_commands ORDER BY rowid DESC").map { try decode($0[0], TagCommand.self) }.filter { !$0.preview.changedAssetIDs.isEmpty } }
  }
  public func undoTagMutation(commandID: String) throws {
    try transaction {
      guard let row = try rows("SELECT data FROM tag_commands WHERE id=?", [commandID]).first else { throw LibraryError.invalid("标签操作不存在") }
      var command = try decode(row[0], TagCommand.self)
      guard !command.preview.changedAssetIDs.isEmpty else { return }
      if command.restored { return }
      _ = try assertAdmitted(command.preview.assetIDs)
      let tags = try loadTags()
      for id in command.preview.changedAssetIDs {
        guard try tagDomain(id).logicalWriterID == command.id, tags[id] == command.preview.after[id] else { throw LibraryError.invalid("标签已有后续修改，不能覆盖") }
      }
      for id in command.preview.changedAssetIDs {
        let domain = try tagDomain(id)
        try writeTags(id, tags: command.preview.before[id]!, domain: TagDomain(revision: domain.revision + 1, logicalWriterID: command.preview.domains[id]?.logicalWriterID))
      }
      command.restored = true
      try statement("UPDATE tag_commands SET data=? WHERE id=?", [try json(command), command.id])
      try operation(entity: command.id, action: "undoTagMutation", payload: try json(command))
    }
  }
}
