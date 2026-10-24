import Foundation

extension LibraryStore {
  func createGroupCommandSchema() throws {
    try exec(
      """
      CREATE TABLE group_commands(id TEXT PRIMARY KEY,data TEXT NOT NULL);
      CREATE TABLE group_domains(group_id TEXT NOT NULL,domain TEXT NOT NULL,revision INTEGER NOT NULL,logical_writer_id TEXT,last_operation_id TEXT,tombstoned INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(group_id,domain));
      """)
    for group in try loadGroups() {
      for domain in Set(
        [GroupTouchDomain.existence, .name, .kind, .lock]
          + group.assetIDs.map { .member(assetID: $0) })
      {
        try writeDomain(
          GroupDomainVersion(groupID: group.id, domain: domain, revision: group.groupRevision),
          tombstoned: false)
      }
      try writeDomain(
        GroupDomainVersion(
          groupID: group.id, domain: .all, revision: group.groupRevision,
          logicalWriterID: try aggregateGroupDigest(group.id)), tombstoned: false)
    }
    try exec("PRAGMA user_version=3")
  }
  private func canonical<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
  }
  private func unique(_ ids: [String], allowEmpty: Bool = false) throws -> [String] {
    guard allowEmpty || !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count
    else { throw LibraryError.invalid("请选择非空、不重复的组或素材") }
    return ids
  }
  private func trimmed(_ value: String) throws -> String {
    let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { throw LibraryError.invalid("名称和用途不能为空") }
    return text
  }
  private func normalize(_ request: GroupCommandRequest) throws -> GroupCommandRequest {
    switch request {
    case .create(let ids, let name, let kind):
      return .create(assetIDs: try unique(ids), name: try trimmed(name), kind: try trimmed(kind))
    case .rename(let id, let name): return .rename(groupID: id, name: try trimmed(name))
    case .setKind(let id, let kind): return .setKind(groupID: id, kind: try trimmed(kind))
    case .setLocked: return request
    case .removeMembers(let id, let ids):
      return .removeMembers(groupID: id, assetIDs: try unique(ids).sorted())
    case .reorder(let id, let ids): return .reorder(groupID: id, assetIDs: try unique(ids))
    case .setParticipation(let groups, let ids, let included):
      return .setParticipation(
        groupIDs: try unique(groups).sorted(), assetIDs: try unique(ids).sorted(),
        included: included)
    case .merge(let ids, let name, let kind):
      guard ids.count >= 2 else { throw LibraryError.invalid("合并至少需要两个组") }
      return .merge(groupIDs: try unique(ids), name: try trimmed(name), kind: try trimmed(kind))
    case .split(let id, let ids, let name, let kind):
      return .split(
        groupID: id, movedAssetIDs: try unique(ids).sorted(), newName: try trimmed(name),
        newKind: try trimmed(kind))
    case .restore: return request
    }
  }
  private func derivedGroupID(_ previewID: String, role: String) throws -> String {
    "group-"
      + LocationIdentity.digest(Data(try canonical(["RAWMaster.group.v1", previewID, role]).utf8))
  }
  private func group(_ id: String) throws -> CaptureGroup {
    guard let g = try optionalGroup(id) else { throw LibraryError.invalid("拍摄组不存在：\(id)") }
    return g
  }
  private func optionalGroup(_ id: String) throws -> CaptureGroup? {
    guard let row = try rows("SELECT data FROM groups_data WHERE id=?", [id]).first else {
      return nil
    }
    var group = try decode(row[0], CaptureGroup.self)
    let members = try rows(
      "SELECT asset_id,included FROM membership WHERE group_id=? ORDER BY position,rowid", [id])
    group.assetIDs = members.map { $0[0] }
    group.includedAssetIDs = members.filter { $0[1] == "1" }.map { $0[0] }
    return group
  }
  private func domain(_ groupID: String, _ domain: GroupTouchDomain) throws -> GroupDomainVersion {
    let row = try rows(
      "SELECT revision,logical_writer_id,last_operation_id FROM group_domains WHERE group_id=? AND domain=?",
      [groupID, domain.key]
    ).first
    return GroupDomainVersion(
      groupID: groupID, domain: domain, revision: Int(row?.first ?? "0") ?? 0,
      logicalWriterID: domain == .all
        ? try aggregateGroupDigest(groupID) : row.flatMap { $0[1].isEmpty ? nil : $0[1] },
      lastOperationID: row.flatMap { $0[2].isEmpty ? nil : $0[2] })
  }
  private func writeDomain(_ value: GroupDomainVersion, tombstoned: Bool) throws {
    try statement(
      "INSERT INTO group_domains VALUES(?,?,?,?,?,?) ON CONFLICT(group_id,domain) DO UPDATE SET revision=excluded.revision,logical_writer_id=excluded.logical_writer_id,last_operation_id=excluded.last_operation_id,tombstoned=excluded.tombstoned",
      [
        value.groupID, value.domain.key, String(value.revision), value.logicalWriterID ?? "",
        value.lastOperationID ?? "", tombstoned ? "1" : "0",
      ])
  }
  private func aggregateGroupDigest(_ id: String) throws -> String {
    let existence =
      try rows(
        "SELECT logical_writer_id FROM group_domains WHERE group_id=? AND domain='existence'", [id]
      ).first?.first ?? ""
    guard let g = try optionalGroup(id) else {
      return LocationIdentity.digest(Data(try canonical(["absent", existence]).utf8))
    }
    var parts = [
      ["present", existence], ["project", g.projectID], ["origin", g.origin.rawValue],
    ]
    for (key, value) in [("name", g.name), ("kind", g.kind), ("lock", String(g.locked))] {
      let head =
        try rows(
          "SELECT logical_writer_id FROM group_domains WHERE group_id=? AND domain=?", [id, key]
        ).first?.first ?? ""
      parts.append([key, value, head])
    }
    let members = g.memberStates
    let heads = try rows(
      "SELECT domain,logical_writer_id FROM group_domains WHERE group_id=? AND domain LIKE 'member:%'",
      [id])
    let byID = Dictionary(uniqueKeysWithValues: heads.map { (String($0[0].dropFirst(7)), $0[1]) })
    for assetID in Set(members.keys).union(byID.keys).sorted() {
      let head = byID[assetID] ?? ""
      if let member = members[assetID] {
        parts.append(["member", assetID, String(member.position), String(member.included), head])
      } else if !head.isEmpty {
        parts.append(["absentMember", assetID, head])
      }
    }
    return LocationIdentity.digest(Data(try canonical(parts).utf8))
  }
  private func deltas(before: [CaptureGroup], after: [CaptureGroup]) -> [GroupDelta] {
    let b = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
    let a = Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0) })
    return Set(b.keys).union(a.keys).sorted().map { GroupDelta.differences(b[$0], a[$0], id: $0) }
      .filter { !$0.domains.isEmpty }
  }
  private func command(_ id: String) throws -> GroupCommandEnvelope {
    guard let row = try rows("SELECT data FROM group_commands WHERE id=?", [id]).first else {
      throw LibraryError.invalid("组操作记录不存在")
    }
    return try decode(row[0], GroupCommandEnvelope.self)
  }
  private func versionMatches(_ expected: GroupDomainVersion, _ current: GroupDomainVersion) -> Bool
  {
    expected.revision == current.revision && expected.logicalWriterID == current.logicalWriterID
      && expected.lastOperationID == current.lastOperationID
  }
  private func valueMatches(
    _ current: CaptureGroup?, _ expected: CaptureGroup?, domain: GroupTouchDomain
  ) -> Bool {
    switch domain {
    case .existence: return (current == nil) == (expected == nil)
    case .name: return current?.name == expected?.name
    case .kind: return current?.kind == expected?.kind
    case .lock: return current?.locked == expected?.locked
    case .member(let id): return current?.memberStates[id] == expected?.memberStates[id]
    case .all: return true  // aggregate digest checks actual values and causal heads
    }
  }
  private func stateMatches(_ record: GroupCommandRecord, after: Bool) throws -> Bool {
    let versions = after ? record.afterDomains : record.beforeDomains
    let expectedGroups = after ? record.after : record.before
    for delta in deltas(before: record.before, after: record.after) {
      let current = try optionalGroup(delta.id)
      let expected = expectedGroups.first { $0.id == delta.id }
      let guards: Set<GroupTouchDomain> =
        delta.domains.contains(.existence) ? [.all, .existence] : delta.domains.union([.existence])
      for touch in guards {
        guard
          let previous = versions.first(where: { $0.groupID == delta.id && $0.domain == touch }),
          try domain(delta.id, touch).logicalWriterID == previous.logicalWriterID,
          valueMatches(current, expected, domain: touch)
        else { return false }
      }
    }
    return true
  }
  private func restoreStatus(_ record: GroupCommandRecord) throws -> GroupRestoreStatus {
    guard record.payloadVersion == 1 else { return .conflict(reason: "不支持的组操作记录版本") }
    if try stateMatches(record, after: true) {
      for delta in deltas(before: record.before, after: record.after) {
        do {
          _ = try inverseGroup(delta, current: optionalGroup(delta.id), record: record)
        } catch let error as LibraryError {
          return .conflict(reason: error.localizedDescription)
        }
      }
      return .available
    }
    if try stateMatches(record, after: false) { return .alreadyReverted }
    return .conflict(reason: "相关组字段或成员在此操作后被修改，请人工复核")
  }
  private func inverseGroup(
    _ original: GroupDelta, current: CaptureGroup?, record: GroupCommandRecord
  ) throws -> CaptureGroup? {
    let restored: CaptureGroup?
    if original.domains.contains(.existence) {
      restored = original.before
    } else {
      guard var g = current, let previous = original.before else {
        throw LibraryError.invalid("组身份已改变")
      }
      var members = g.memberStates
      for touch in original.domains {
        switch touch {
        case .name: g.name = previous.name
        case .kind: g.kind = previous.kind
        case .lock: g.locked = previous.locked
        case .member(let assetID): members[assetID] = previous.memberStates[assetID]
        default: break
        }
      }
      g.assetIDs = members.keys.sorted { a, b in
        let lhs = members[a]!.position
        let rhs = members[b]!.position
        return lhs == rhs ? a < b : lhs < rhs
      }
      g.includedAssetIDs = g.assetIDs.filter { members[$0]!.included }
      restored = g
    }
    // Compact positions can collide when independently removed members are restored.
    // Reindexing must not silently acquire another command's member domain.
    let inverse = GroupDelta.differences(current, restored, id: original.id)
    guard inverse.domains.isSubset(of: original.domains) else {
      throw LibraryError.invalid("恢复将改变此操作未修改的组字段或成员顺序，请先撤销相关操作或人工复核")
    }
    for touch in inverse.domains {
      guard
        record.beforeDomains.contains(where: {
          $0.groupID == original.id && $0.domain == touch
        })
      else { throw LibraryError.invalid("组操作缺少恢复所需的字段历史，请人工复核") }
    }
    return restored
  }
  public func loadGroupCommands(limit: Int = 50) throws -> [GroupCommandRecord] {
    try locked {
      let records = try rows(
        "SELECT data FROM group_commands ORDER BY rowid DESC LIMIT ?",
        [String(max(0, min(limit, 1000)))]
      ).map { try decode($0[0], GroupCommandEnvelope.self).record }
      return try records.map {
        var r = $0
        r.restoreStatus = try restoreStatus(r)
        return r
      }
    }
  }
  public func previewGroupCommand(_ request: GroupCommandRequest) throws -> GroupCommandPreview {
    try locked { try buildGroupPreview(normalize(request), id: UUID().uuidString, choices: nil) }
  }
  private func buildGroupPreview(
    _ request: GroupCommandRequest, id: String, choices: [String: Bool]?
  ) throws -> GroupCommandPreview {
    var before: [CaptureGroup] = []
    var after: [CaptureGroup] = []
    var conflicts: [GroupParticipationConflict] = []
    var warnings: [String] = []
    var required: [String: Set<GroupTouchDomain>] = [:]
    func depend(_ group: String, _ domains: Set<GroupTouchDomain>) {
      required[group, default: []].formUnion(domains)
    }
    func fresh(_ role: String) throws -> String {
      let value = try derivedGroupID(id, role: role)
      guard try optionalGroup(value) == nil,
        try rows("SELECT domain FROM group_domains WHERE group_id=?", [value]).isEmpty
      else { throw LibraryError.invalid("新组身份已存在，请重新预览") }
      return value
    }
    func sameProject(_ groups: [CaptureGroup]) throws {
      guard Set(groups.map(\.projectID)).count <= 1 else {
        throw LibraryError.invalid("不能跨项目修改拍摄组")
      }
    }
    switch request {
    case .create(let ids, let name, let kind):
      let assets = try ids.map { try asset($0) }
      guard Set(assets.map(\.projectID)).count == 1 else { throw LibraryError.invalid("不能跨项目建组") }
      let g = CaptureGroup(
        id: try fresh("create:0"), projectID: assets[0].projectID, name: name, kind: kind,
        assetIDs: ids, includedAssetIDs: ids)
      after = [g]
    case .rename(let groupID, let name):
      var g = try group(groupID)
      before = [g]
      g.name = name
      g.locked = true
      after = [g]
      depend(groupID, [.existence, .name, .lock])
    case .setKind(let groupID, let kind):
      var g = try group(groupID)
      before = [g]
      g.kind = kind
      g.locked = true
      after = [g]
      depend(groupID, [.existence, .kind, .lock])
    case .setLocked(let groupID, let locked):
      var g = try group(groupID)
      before = [g]
      g.locked = locked
      after = [g]
      depend(groupID, [.existence, .lock])
    case .removeMembers(let groupID, let ids):
      var g = try group(groupID)
      before = [g]
      guard Set(ids).isSubset(of: Set(g.assetIDs)) else { throw LibraryError.invalid("移出范围包含非组成员") }
      g.assetIDs.removeAll { ids.contains($0) }
      g.includedAssetIDs.removeAll { ids.contains($0) }
      g.locked = true
      after = [g]
      depend(groupID, [.existence, .lock])
      if g.assetIDs.isEmpty { warnings.append("移出后将保留一个空拍摄组") }
    case .reorder(let groupID, let ids):
      var g = try group(groupID)
      before = [g]
      guard Set(ids) == Set(g.assetIDs), ids.count == g.assetIDs.count else {
        throw LibraryError.invalid("排序必须包含全部成员且不能重复")
      }
      g.assetIDs = ids
      g.locked = true
      after = [g]
      depend(groupID, Set([.existence, .lock] + ids.map { .member(assetID: $0) }))
    case .setParticipation(let groupIDs, let ids, let included):
      before = try groupIDs.map { try group($0) }
      try sameProject(before)
      guard Set(ids).isSubset(of: Set(before.flatMap(\.assetIDs))) else {
        throw LibraryError.invalid("参与范围包含非组成员")
      }
      for original in before {
        let affected = Set(original.assetIDs).intersection(ids)
        guard !affected.isEmpty else { throw LibraryError.invalid("指定组没有选中的成员") }
        var g = original
        let includedSet = Set(g.includedAssetIDs)
        g.includedAssetIDs = g.assetIDs.filter {
          affected.contains($0) ? included : includedSet.contains($0)
        }
        g.locked = true
        after.append(g)
        depend(g.id, Set([.existence, .lock] + affected.map { .member(assetID: $0) }))
      }
    case .merge(let groupIDs, let name, let kind):
      before = try groupIDs.map { try group($0) }
      try sameProject(before)
      var order: [String] = []
      var values: [String: [GroupParticipationValue]] = [:]
      for g in before {
        for assetID in g.assetIDs {
          if values[assetID] == nil { order.append(assetID) }
          values[assetID, default: []].append(
            GroupParticipationValue(groupID: g.id, included: g.includedAssetIDs.contains(assetID)))
        }
      }
      guard !order.isEmpty else { throw LibraryError.invalid("合并结果不能为空") }
      conflicts = order.compactMap { assetID in
        let v = values[assetID]!
        return Set(v.map(\.included)).count > 1
          ? GroupParticipationConflict(assetID: assetID, values: v) : nil
      }
      if let choices {
        guard Set(choices.keys) == Set(conflicts.map(\.assetID)) else {
          throw LibraryError.invalid("请为每个参与冲突作出选择，不能附加其他素材")
        }
      }
      let included = order.filter { choices?[$0] ?? values[$0]!.first!.included }
      after = [
        CaptureGroup(
          id: try fresh("merge:0"), projectID: before[0].projectID, name: name, kind: kind,
          assetIDs: order, includedAssetIDs: included)
      ]
      for g in before { depend(g.id, [.all, .existence]) }
    case .split(let groupID, let ids, let name, let kind):
      var g = try group(groupID)
      before = [g]
      guard Set(ids).isSubset(of: Set(g.assetIDs)), ids.count < g.assetIDs.count else {
        throw LibraryError.invalid("拆分必须留下两个非空组")
      }
      let moved = g.assetIDs.filter { ids.contains($0) }
      let included = g.includedAssetIDs.filter { ids.contains($0) }
      g.assetIDs.removeAll { ids.contains($0) }
      g.includedAssetIDs.removeAll { ids.contains($0) }
      g.locked = true
      after = [
        g,
        CaptureGroup(
          id: try fresh("split:0"), projectID: g.projectID, name: name, kind: kind, assetIDs: moved,
          includedAssetIDs: included),
      ]
      depend(groupID, [.existence, .lock])
    case .restore(let commandID):
      let original = try command(commandID).record
      guard case .available = try restoreStatus(original) else {
        throw LibraryError.invalid("此操作已恢复或存在后续冲突，请人工复核")
      }
      for delta in deltas(before: original.before, after: original.after) {
        let current = try optionalGroup(delta.id)
        if let current { before.append(current) }
        if let restored = try inverseGroup(delta, current: current, record: original) {
          after.append(restored)
        }
        if delta.domains.contains(.existence) {
          depend(delta.id, [.all, .existence])
        } else {
          depend(delta.id, delta.domains.union([.existence]))
        }
      }
    }
    let changes = deltas(before: before, after: after)
    guard !changes.isEmpty else { throw LibraryError.invalid("没有可修改的组状态") }
    for delta in changes {
      depend(delta.id, delta.domains.union([.existence]))
      if delta.domains.contains(.existence) { depend(delta.id, [.all]) }
    }
    let deps = try required.keys.sorted().flatMap { group in
      try required[group]!.sorted { $0.key < $1.key }.map { try domain(group, $0) }
    }
    for g in before where !g.locked && after.first(where: { $0.id == g.id })?.locked == true {
      warnings.append("“\(g.name)”修改后将锁定，保护人工组结构")
    }
    if !choices.isEmptyOrNil && conflicts.isEmpty { throw LibraryError.invalid("此操作不接受参与冲突选择") }
    return GroupCommandPreview(
      id: id, request: request, before: before, after: after, inclusionConflicts: conflicts,
      warnings: warnings, dependencies: deps)
  }
  public func commitGroupCommand(
    _ preview: GroupCommandPreview, participationResolutions: [String: Bool] = [:]
  ) throws -> GroupCommandRecord {
    try transaction {
      let request = try normalize(preview.request)
      let requestDigest = try canonical(request)
      if !(try rows("SELECT id FROM group_commands WHERE id=?", [preview.id])).isEmpty {
        var envelope = try command(preview.id)
        guard envelope.requestDigest == requestDigest, envelope.choices == participationResolutions
        else { throw LibraryError.invalid("同一操作身份已用于不同请求或参与选择") }
        envelope.record.restoreStatus = try restoreStatus(envelope.record)
        return envelope.record
      }
      let derived = try buildGroupPreview(
        request, id: preview.id, choices: participationResolutions)
      let expected = Dictionary(
        preview.dependencies.map { ($0.groupID + "|" + $0.domain.key, $0) },
        uniquingKeysWith: { first, _ in first })
      guard expected.count == preview.dependencies.count else {
        throw LibraryError.invalid("重复组依赖")
      }
      for current in derived.dependencies {
        guard let prior = expected[current.groupID + "|" + current.domain.key],
          versionMatches(prior, current)
        else { throw LibraryError.invalid("预览后相关组状态已改变，请重新预览") }
      }
      for previous in preview.dependencies {
        guard versionMatches(previous, try domain(previous.groupID, previous.domain)) else {
          throw LibraryError.invalid("预览后组依赖已改变，请重新预览")
        }
      }
      let changes = deltas(before: derived.before, after: derived.after)
      var beforeDomains: [GroupDomainVersion] = []
      for delta in changes {
        for touch in delta.domains.union([.all, .existence]).sorted(by: { $0.key < $1.key }) {
          beforeDomains.append(try domain(delta.id, touch))
        }
      }
      let original: GroupCommandRecord?
      if case .restore(let target) = request {
        original = try command(target).record
      } else {
        original = nil
      }
      for delta in changes {
        try applyGroupDelta(delta, commandID: preview.id, restoring: original)
      }
      var afterDomains: [GroupDomainVersion] = []
      for before in beforeDomains { afterDomains.append(try domain(before.groupID, before.domain)) }
      let after = try derived.after.map { try group($0.id) }
      let record = GroupCommandRecord(
        id: preview.id, request: request, before: derived.before, after: after,
        beforeDomains: beforeDomains, afterDomains: afterDomains, compensates: original?.id)
      let envelope = GroupCommandEnvelope(
        record: record, requestDigest: requestDigest, choices: participationResolutions)
      try statement("INSERT INTO group_commands VALUES(?,?)", [record.id, try json(envelope)])
      if let original {
        var parent = try command(original.id)
        parent.record.compensationIDs.append(record.id)
        try statement(
          "UPDATE group_commands SET data=? WHERE id=?", [try json(parent), original.id])
      }
      try operation(entity: record.id, action: "groupCommand", payload: try json(record))
      return record
    }
  }
  public func undoGroupCommand(id: String, requestID: String = UUID().uuidString) throws
    -> GroupCommandRecord
  {
    try locked {
      if !(try rows("SELECT id FROM group_commands WHERE id=?", [requestID])).isEmpty {
        let existing = try command(requestID)
        guard existing.requestDigest == (try canonical(normalize(.restore(commandID: id)))) else {
          throw LibraryError.invalid("恢复请求身份冲突")
        }
        return existing.record
      }
      let preview = try buildGroupPreview(.restore(commandID: id), id: requestID, choices: nil)
      return try commitGroupCommand(preview)
    }
  }
  private func applyGroupDelta(
    _ delta: GroupDelta, commandID: String, restoring: GroupCommandRecord?
  ) throws {
    var restoredDomains: [GroupTouchDomain: GroupDomainVersion] = [:]
    if let restoring {
      for touch in delta.domains where touch != .all {
        guard
          let prior = restoring.beforeDomains.first(where: {
            $0.groupID == delta.id && $0.domain == touch
          })
        else { throw LibraryError.invalid("组操作缺少恢复所需的字段历史，请人工复核") }
        restoredDomains[touch] = prior
      }
    }
    let oldAll = try domain(delta.id, .all)
    if var after = delta.after {
      after.groupRevision = oldAll.revision + 1
      try statement(
        "INSERT INTO groups_data VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data",
        [after.id, after.projectID, try json(after)])
      for touch in delta.domains {
        if case .member(let id) = touch {
          if let member = after.memberStates[id] {
            try statement(
              "INSERT INTO membership VALUES(?,?,?,?) ON CONFLICT(group_id,asset_id) DO UPDATE SET position=excluded.position,included=excluded.included",
              [after.id, id, String(member.position), member.included ? "1" : "0"])
          } else {
            try statement("DELETE FROM membership WHERE group_id=? AND asset_id=?", [after.id, id])
          }
        }
      }
      try statement("UPDATE group_domains SET tombstoned=0 WHERE group_id=?", [after.id])
    } else {
      try statement("DELETE FROM membership WHERE group_id=?", [delta.id])
      try statement("DELETE FROM groups_data WHERE id=?", [delta.id])
      try statement("UPDATE group_domains SET tombstoned=1 WHERE group_id=?", [delta.id])
    }
    for touch in delta.domains where touch != .all {
      let before = try domain(delta.id, touch)
      try writeDomain(
        GroupDomainVersion(
          groupID: delta.id, domain: touch, revision: before.revision + 1,
          logicalWriterID: restoring == nil ? commandID : restoredDomains[touch]!.logicalWriterID,
          lastOperationID: commandID),
        tombstoned: delta.after == nil)
    }
    try writeDomain(
      GroupDomainVersion(
        groupID: delta.id, domain: .all, revision: oldAll.revision + 1,
        logicalWriterID: try aggregateGroupDigest(delta.id), lastOperationID: commandID),
      tombstoned: delta.after == nil)
  }
}

extension Optional where Wrapped == [String: Bool] {
  fileprivate var isEmptyOrNil: Bool { self?.isEmpty ?? true }
}
