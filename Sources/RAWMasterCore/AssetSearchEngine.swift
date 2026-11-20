import Foundation

/// Pure metadata filtering. The caller supplies an admitted, explicit scope; no files are opened.
public enum AssetSearchEngine {
  private static let locale = Locale(identifier: "en_US_POSIX")
  private static func folded(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: locale)
  }
  public static func cameraDisplayName(_ value: String) -> String {
    value.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)).precomposedStringWithCanonicalMapping
  }
  public static func cameraKey(_ value: String) -> String { folded(cameraDisplayName(value)) }
  public static func filter(assets: [AssetRecord], query: ProjectSearchQuery,
                            tags: [String: [String]], reviewedIDs: Set<String>,
                            sort: ProjectReviewSort = .original, colorLabels: [String: PhotoColorLabel] = [:]) throws -> [AssetRecord] {
    try query.validate()
    let filename = folded(query.filename.trimmingCharacters(in: .whitespacesAndNewlines))
    let camera = query.camera.map(cameraKey).flatMap { $0.isEmpty ? nil : $0 }
    let wantedTags = Set(try TagText.normalized(query.tags).map(TagText.key))
    var result = assets.filter { asset in
      if !filename.isEmpty && !folded(asset.filename).contains(filename) { return false }
      if let camera, asset.camera.map(cameraKey) != camera { return false }
      if let start = query.capturedFrom, asset.capturedAt.map({ $0 >= start }) != true { return false }
      if let end = query.capturedBefore, asset.capturedAt.map({ $0 < end }) != true { return false }
      if let low = query.minimumRating, asset.rating < low { return false }
      if let high = query.maximumRating, asset.rating > high { return false }
      if let decision = query.decision, asset.decision != decision { return false }
      if let availability = query.availability, asset.availability != availability { return false }
      if let label = query.colorLabel, colorLabels[asset.id] != label { return false }
      switch query.review {
      case .all: break
      case .reviewed: if !reviewedIDs.contains(asset.id) { return false }
      case .unreviewed: if reviewedIDs.contains(asset.id) { return false }
      }
      if !wantedTags.isEmpty {
        let actual = Set((tags[asset.id] ?? []).map(TagText.key))
        if query.tagMatch == .all && !wantedTags.isSubset(of: actual) { return false }
        if query.tagMatch == .any && wantedTags.isDisjoint(with: actual) { return false }
      }
      return true
    }
    guard sort != .original else { return result }
    // Stable tie breaking retains the caller's established session/member order.
    let rank = Dictionary(uniqueKeysWithValues: assets.enumerated().map { ($0.element.id, $0.offset) })
    result.sort { lhs, rhs in
      switch sort {
      case .original: break
      case .filename:
        let comparison = lhs.filename.compare(rhs.filename, options: [.numeric, .caseInsensitive], locale: locale)
        if comparison != .orderedSame { return comparison == .orderedAscending }
      case .capturedAscending, .capturedDescending:
        if lhs.capturedAt != rhs.capturedAt {
          guard let left = lhs.capturedAt else { return false }
          guard let right = rhs.capturedAt else { return true }
          return sort == .capturedAscending ? left < right : left > right
        }
      case .ratingDescending: if lhs.rating != rhs.rating { return lhs.rating > rhs.rating }
      }
      return (rank[lhs.id] ?? 0) < (rank[rhs.id] ?? 0)
    }
    return result
  }
}
