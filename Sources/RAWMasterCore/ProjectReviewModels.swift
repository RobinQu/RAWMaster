import Foundation

public enum SearchTagMatch: String, Codable, Sendable, CaseIterable { case all, any }
public enum ReviewFilter: String, Codable, Sendable, CaseIterable { case all, reviewed, unreviewed }
public enum ProjectReviewSort: String, Codable, Sendable, CaseIterable { case original, filename, capturedAscending, capturedDescending, ratingDescending }

public struct ProjectSearchQuery: Codable, Sendable, Equatable {
  public var filename: String
  public var capturedFrom: Date?
  public var capturedBefore: Date?
  public var timeZoneIdentifier: String
  public var camera: String?
  public var minimumRating: Int?
  public var maximumRating: Int?
  public var tags: [String]
  public var tagMatch: SearchTagMatch
  public var decision: Decision?
  public var availability: AssetAvailability?
  public var review: ReviewFilter
  public var colorLabel: PhotoColorLabel?
  public init(filename: String = "", capturedFrom: Date? = nil, capturedBefore: Date? = nil,
              timeZoneIdentifier: String = TimeZone.current.identifier, camera: String? = nil,
              minimumRating: Int? = nil, maximumRating: Int? = nil, tags: [String] = [],
              tagMatch: SearchTagMatch = .all, decision: Decision? = nil,
              availability: AssetAvailability? = nil, review: ReviewFilter = .all, colorLabel: PhotoColorLabel? = nil) {
    self.filename = filename; self.capturedFrom = capturedFrom; self.capturedBefore = capturedBefore
    self.timeZoneIdentifier = timeZoneIdentifier; self.camera = camera
    self.minimumRating = minimumRating; self.maximumRating = maximumRating; self.tags = tags
    self.tagMatch = tagMatch; self.decision = decision; self.availability = availability; self.review = review; self.colorLabel = colorLabel
  }
  public var isEmpty: Bool {
    filename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && capturedFrom == nil && capturedBefore == nil
      && (camera?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
      && minimumRating == nil && maximumRating == nil && tags.isEmpty && decision == nil && availability == nil && review == .all && colorLabel == nil
  }
  public func validate() throws {
    guard TimeZone(identifier: timeZoneIdentifier) != nil, filename.count <= 1024, tags.count <= 100,
          capturedFrom.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
          capturedBefore.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
          minimumRating.map({ (0...5).contains($0) }) ?? true,
          maximumRating.map({ (0...5).contains($0) }) ?? true else { throw LibraryError.invalid("搜索条件无效") }
    if let low = minimumRating, let high = maximumRating, low > high { throw LibraryError.invalid("最低星级不能高于最高星级") }
    if let start = capturedFrom, let end = capturedBefore, start >= end { throw LibraryError.invalid("结束日期必须晚于起始日期") }
  }
  public mutating func setDateRange(startDay: Date?, endDay: Date?, timeZone: TimeZone) throws {
    guard startDay.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true,
          endDay.map({ $0.timeIntervalSinceReferenceDate.isFinite }) ?? true else { throw LibraryError.invalid("日期无效") }
    var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
    var next = self
    next.capturedFrom = startDay.map { calendar.startOfDay(for: $0) }
    next.capturedBefore = try endDay.map { day in
      guard let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) else { throw LibraryError.invalid("日期无法解析") }
      return end
    }
    next.timeZoneIdentifier = timeZone.identifier
    try next.validate()
    self = next
  }
}

public struct ReviewRecord: Codable, Sendable, Identifiable {
  public var id: String { assetID }
  public var assetID: String
  public var projectID: String
  public var reviewed: Bool
  public var updatedAt: Date
  public init(assetID: String, projectID: String, reviewed: Bool, updatedAt: Date = Date()) {
    self.assetID = assetID; self.projectID = projectID; self.reviewed = reviewed; self.updatedAt = updatedAt
  }
}
public struct ProjectReviewState: Codable, Sendable, Identifiable {
  public var id: String { projectID }
  public var projectID: String
  public var revision: Int
  public var query: ProjectSearchQuery
  public var sort: ProjectReviewSort
  public var mode: String
  public var focusedAssetID: String?
  public var selectedAssetIDs: [String]
  public var expandedPairIDs: [String]
  public var rawPreviewPairIDs: [String]
  public var syncCompare: Bool
  public init(projectID: String, revision: Int = 0, query: ProjectSearchQuery = ProjectSearchQuery(), sort: ProjectReviewSort = .original,
              mode: String = "grid", focusedAssetID: String? = nil, selectedAssetIDs: [String] = [],
              expandedPairIDs: [String] = [], rawPreviewPairIDs: [String] = [], syncCompare: Bool = true) {
    self.projectID = projectID; self.revision = revision; self.query = query; self.sort = sort; self.mode = mode
    self.focusedAssetID = focusedAssetID; self.selectedAssetIDs = selectedAssetIDs; self.expandedPairIDs = expandedPairIDs
    self.rawPreviewPairIDs = rawPreviewPairIDs; self.syncCompare = syncCompare
  }
}
public struct ReviewProgress: Codable, Sendable {
  public var totalFiles: Int
  public var reviewedFiles: Int
  public var totalCaptures: Int
  public var reviewedCaptures: Int
  public var partiallyReviewedCaptures: Int
  public var sequenceOnlyFiles: Int
  public init(totalFiles: Int = 0, reviewedFiles: Int = 0, totalCaptures: Int = 0, reviewedCaptures: Int = 0, partiallyReviewedCaptures: Int = 0, sequenceOnlyFiles: Int = 0) {
    self.totalFiles = totalFiles; self.reviewedFiles = reviewedFiles; self.totalCaptures = totalCaptures
    self.reviewedCaptures = reviewedCaptures; self.partiallyReviewedCaptures = partiallyReviewedCaptures; self.sequenceOnlyFiles = sequenceOnlyFiles
  }
  public static func calculate(assetIDs: Set<String>, reviewedIDs: Set<String>, pairs: [CapturePair], sequenceOnlyIDs: Set<String> = []) -> ReviewProgress {
    let reviewed = reviewedIDs.intersection(assetIDs)
    var pairKeys: [String: String] = [:]
    for pair in pairs where Set(pair.assetIDs).isSubset(of: assetIDs) {
      for id in pair.assetIDs { pairKeys[id] = "pair:" + pair.id }
    }
    var events: [String: Set<String>] = [:]
    for id in assetIDs { events[pairKeys[id] ?? "asset:" + id, default: []].insert(id) }
    let captures = Array(events.values)
    return ReviewProgress(totalFiles: assetIDs.count, reviewedFiles: reviewed.count, totalCaptures: captures.count,
                          reviewedCaptures: captures.filter { $0.isSubset(of: reviewed) }.count,
                          partiallyReviewedCaptures: captures.filter { !$0.isDisjoint(with: reviewed) && !$0.isSubset(of: reviewed) }.count,
                          sequenceOnlyFiles: sequenceOnlyIDs.intersection(assetIDs).count)
  }
}

public enum TagMutationMode: String, Codable, Sendable, CaseIterable { case add, remove, replace }
public struct TagDomain: Codable, Sendable, Equatable {
  public var revision: Int
  public var logicalWriterID: String?
  public init(revision: Int = 0, logicalWriterID: String? = nil) { self.revision = revision; self.logicalWriterID = logicalWriterID }
}
public struct TagMutationPreview: Codable, Sendable, Identifiable {
  public var id: String
  public var mode: TagMutationMode
  public var tags: [String]
  public var assetIDs: [String]
  public var before: [String: [String]]
  public var after: [String: [String]]
  public var domains: [String: TagDomain]
  public var commonTags: [String]
  public var mixedTags: [String]
  public var changedAssetIDs: [String] { assetIDs.filter { before[$0] != after[$0] } }
}
public struct TagCommand: Codable, Sendable, Identifiable {
  public var id: String { preview.id }
  public var preview: TagMutationPreview
  public var restored: Bool
  public var createdAt: Date
}

public enum TagText {
  public static func key(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
  public static func normalized(_ values: [String]) throws -> [String] {
    var seen = Set<String>(), result: [String] = []
    for item in values {
      let value = item.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
      if value.isEmpty { continue }
      guard value.count <= 128 else { throw LibraryError.invalid("标签长度超限") }
      if seen.insert(key(value)).inserted { result.append(value) }
    }
    guard result.count <= 100 else { throw LibraryError.invalid("标签数量超限") }
    return result.sorted()
  }
}
