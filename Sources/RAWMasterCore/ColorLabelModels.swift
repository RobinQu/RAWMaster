import Foundation

/// A photo has at most one color label, independent from its text tags.
public enum PhotoColorLabel: String, Codable, Sendable, CaseIterable {
  case red, orange, yellow, green, blue, purple, gray
  public var title: String {
    switch self { case .red: "红色"; case .orange: "橙色"; case .yellow: "黄色"; case .green: "绿色"; case .blue: "蓝色"; case .purple: "紫色"; case .gray: "灰色" }
  }
}
public struct AssetColorLabelRecord: Codable, Sendable, Equatable {
  public var assetID: String
  public var label: PhotoColorLabel?
  public var revision: Int
  public var logicalWriterID: String?
  public init(assetID: String, label: PhotoColorLabel? = nil, revision: Int = 0, logicalWriterID: String? = nil) {
    self.assetID = assetID; self.label = label; self.revision = revision; self.logicalWriterID = logicalWriterID
  }
}
public struct ColorLabelCommand: Codable, Sendable, Identifiable {
  public var id: String
  public var before: [AssetColorLabelRecord]
  public var after: [AssetColorLabelRecord]
  public var createdAt: Date
  public var restored: Bool
}
