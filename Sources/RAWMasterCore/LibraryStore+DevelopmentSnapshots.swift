import Foundation

package struct DevelopmentSnapshot: Codable, Equatable, Sendable, Identifiable {
  package let id: UUID
  package var name: String
  package let createdAt: Date
  package let recipe: DevelopmentRecipe
  package let presetAdoptions: [DevelopmentPresetAdoption]?
}

package struct DevelopmentSnapshotScope: Codable, Hashable, Sendable {
  package enum Appearance: String, Codable, Sendable { case compatibility, hdr }
  package let workID: String
  package let parentVersionID: String
  package let appearance: Appearance

  package init(workID: String, parentVersionID: String, appearance: Appearance) {
    self.workID = workID
    self.parentVersionID = parentVersionID
    self.appearance = appearance
  }

  fileprivate var metadataKey: String {
    get throws { "editing.namedSnapshots.v1." + (try EditingFingerprint.of(self)) }
  }
}

package enum DevelopmentSnapshotError: LocalizedError {
  case limit, invalidName, missing, changedContext

  package var errorDescription: String? {
    switch self {
    case .limit: "此分支已有 32 个命名快照。删除一个后可以继续保存。"
    case .invalidName: "请输入 1 到 60 个字符的快照名称。"
    case .missing: "这份快照已被删除。请取消并返回快照列表。"
    case .changedContext: "当前照片或调色分支已改变。请取消并重新选择快照。"
    }
  }
}

package enum DevelopmentSnapshotEdit: Sendable {
  case create(id: UUID, name: String?, createdAt: Date, recipe: DevelopmentRecipe, adoptions: [DevelopmentPresetAdoption]?)
  case rename(UUID, String)
  case delete(UUID)

  package func apply(to snapshots: inout [DevelopmentSnapshot]) throws {
    switch self {
    case let .create(id, name, date, recipe, adoptions):
      if let previous = snapshots.first(where: { $0.id == id }) {
        guard previous.recipe == recipe, previous.presetAdoptions == adoptions else { throw EditingError.commandConflict }
        return
      }
      guard snapshots.count < 32 else { throw DevelopmentSnapshotError.limit }
      let title = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      var number = snapshots.count + 1
      while title.isEmpty && snapshots.contains(where: { $0.name == "快照 \(number)" }) { number += 1 }
      snapshots.append(.init(id: id, name: title.isEmpty ? "快照 \(number)" : String(title.prefix(60)),
        createdAt: date, recipe: recipe, presetAdoptions: adoptions))
    case let .rename(id, name):
      let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !title.isEmpty, title.count <= 60 else { throw DevelopmentSnapshotError.invalidName }
      guard let index = snapshots.firstIndex(where: { $0.id == id }) else { throw DevelopmentSnapshotError.missing }
      snapshots[index].name = title
    case let .delete(id):
      snapshots.removeAll { $0.id == id }
    }
  }
}

extension LibraryStore {
  /// The same metadata table is present in earlier catalogs and travels in the SQLite backup.
  package func developmentSnapshots(in scope: DevelopmentSnapshotScope) throws -> [DevelopmentSnapshot] {
    try withReadSnapshot {
      let parent = try editingVersion(id: scope.parentVersionID)
      guard parent.workID == scope.workID else { throw EditingError.invalidParent }
      return try readDevelopmentSnapshots(key: scope.metadataKey)
    }
  }

  /// Apply one command to the latest collection under BEGIN IMMEDIATE, including the capacity check.
  package func updateDevelopmentSnapshots(in scope: DevelopmentSnapshotScope, _ edit: DevelopmentSnapshotEdit) throws -> [DevelopmentSnapshot] {
    try transaction {
      let work = try photoWork(id: scope.workID)
      let parent = try editingVersion(id: scope.parentVersionID)
      guard parent.workID == work.id, work.source.hasSameIdentity(as: parent.source) else { throw EditingError.invalidParent }
      if case let .create(_, _, _, recipe, adoptions) = edit {
        try recipe.validate()
        guard (recipe.sceneGraph != nil) == (scope.appearance == .hdr),
              recipe.sceneGraph == nil || adoptions == nil else { throw EditingError.invalidRecipe }
        try validateSceneRecipeSource(recipe, source: work.source)
      }
      let key = try scope.metadataKey
      var snapshots = try readDevelopmentSnapshots(key: key)
      try edit.apply(to: &snapshots)
      if snapshots.isEmpty {
        try statement("DELETE FROM metadata WHERE key=?", [key])
      } else {
        try statement("INSERT INTO metadata(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
          [key, try json(snapshots)])
      }
      return snapshots
    }
  }

  private func readDevelopmentSnapshots(key: String) throws -> [DevelopmentSnapshot] {
    guard let value = try rows("SELECT value FROM metadata WHERE key=?", [key]).first?.first else { return [] }
    return try decode(value, [DevelopmentSnapshot].self)
  }
}
