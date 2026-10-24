import Foundation

/// Mirrors AssetBrowserOrder v1. Adopting this helper in App is a separate integration step.
public enum SequenceBaseOrder {
  public static let version = "session-natural-path-v1"

  public static func sorted(_ assets: [AssetRecord], sessions: [ImportSession]) -> [AssetRecord] {
    let ranks = Dictionary(
      sessions.enumerated().map { ($0.element.id, $0.offset) },
      uniquingKeysWith: { first, _ in first })
    let locale = Locale(identifier: "en_US_POSIX")
    return assets.sorted { left, right in
      let leftRank = ranks[left.sessionID] ?? Int.max
      let rightRank = ranks[right.sessionID] ?? Int.max
      if leftRank != rightRank { return leftRank < rightRank }
      if left.sessionID != right.sessionID { return left.sessionID < right.sessionID }
      let order = left.relativePath.compare(
        right.relativePath, options: [.numeric, .caseInsensitive], locale: locale)
      if order != .orderedSame { return order == .orderedAscending }
      if left.relativePath != right.relativePath { return left.relativePath < right.relativePath }
      return left.id < right.id
    }
  }
}
