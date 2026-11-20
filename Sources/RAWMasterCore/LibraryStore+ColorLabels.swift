import Foundation

extension LibraryStore {
  func createColorLabelSchema() throws {
    try exec("CREATE TABLE asset_color_labels(asset_id TEXT PRIMARY KEY, data TEXT NOT NULL)")
    try exec("PRAGMA user_version=6")
  }
  public func loadColorLabelRecords() throws -> [AssetColorLabelRecord] {
    try locked {
      try rows("SELECT asset_id,data FROM asset_color_labels ORDER BY rowid").map { row in
        let value = try decode(row[1], AssetColorLabelRecord.self)
        guard value.assetID == row[0], value.revision >= 0 else { throw LibraryError.invalid("颜色标签记录无效") }
        return value
      }
    }
  }
  public func loadColorLabels() throws -> [String: PhotoColorLabel] {
    Dictionary(uniqueKeysWithValues: try loadColorLabelRecords().compactMap { record in record.label.map { (record.assetID, $0) } })
  }
  private func writeColorLabel(_ record: AssetColorLabelRecord) throws {
    try statement("INSERT INTO asset_color_labels VALUES(?,?) ON CONFLICT(asset_id) DO UPDATE SET data=excluded.data", [record.assetID, try json(record)])
  }
  /// Commands live in the existing durable operation journal. Clearing keeps a revisioned tombstone.
  @discardableResult public func setColorLabel(ids: [String], label: PhotoColorLabel?) throws -> ColorLabelCommand? {
    try transaction {
      let targets = try Array(Set(ids)).sorted().map { try asset($0) }
      guard !targets.isEmpty else { return nil }
      let existing = Dictionary(uniqueKeysWithValues: try loadColorLabelRecords().map { ($0.assetID, $0) })
      let id = UUID().uuidString
      let before = targets.map { existing[$0.id] ?? AssetColorLabelRecord(assetID: $0.id) }.filter { $0.label != label }
      guard !before.isEmpty else { return nil }
      let after = before.map { AssetColorLabelRecord(assetID: $0.assetID, label: label, revision: $0.revision + 1, logicalWriterID: id) }
      let command = ColorLabelCommand(id: id, before: before, after: after, createdAt: Date(), restored: false)
      for record in after { try writeColorLabel(record) }
      try operation(entity: id, action: "colorLabelMutation", payload: try json(command))
      return command
    }
  }
  public func loadColorLabelCommands() throws -> [ColorLabelCommand] {
    try locked {
      let restored = Set(try rows("SELECT entity_id FROM operations WHERE action='undoColorLabelMutation'").map { $0[0] })
      return try rows("SELECT payload FROM operations WHERE action='colorLabelMutation' ORDER BY rowid DESC").map {
        var command = try decode($0[0], ColorLabelCommand.self)
        command.restored = restored.contains(command.id)
        return command
      }
    }
  }
  public func undoColorLabel(commandID: String) throws {
    try transaction {
      guard let command = try loadColorLabelCommands().first(where: { $0.id == commandID }) else { throw LibraryError.invalid("颜色标签操作不存在") }
      guard !command.restored else { return }
      let current = Dictionary(uniqueKeysWithValues: try loadColorLabelRecords().map { ($0.assetID, $0) })
      for record in command.after {
        guard let latest = current[record.assetID], latest.label == record.label, latest.logicalWriterID == commandID else {
          throw LibraryError.invalid("颜色标签已有后续修改，不能覆盖")
        }
      }
      for record in command.before {
        _ = try asset(record.assetID)
        let next = AssetColorLabelRecord(assetID: record.assetID, label: record.label, revision: (current[record.assetID]?.revision ?? 0) + 1, logicalWriterID: record.logicalWriterID)
        try writeColorLabel(next)
      }
      try operation(entity: commandID, action: "undoColorLabelMutation", payload: try json(command))
    }
  }
}
