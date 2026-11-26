import Foundation

/// Persisted scene operations. Preview selection is deliberately not part of this value.
public struct DevelopmentSceneWorkflowV1: Codable, Equatable, Sendable {
  public enum Failure: Error, Equatable {
    case unsupportedSchema, invalidNodes, invalidExposure, unknownNode
  }

  public struct Corrector: Codable, Equatable, Sendable {
    public let id: UUID
    public let enabled: Bool
    public let exposureEV: Float

    public init(id: UUID = UUID(), enabled: Bool = true, exposureEV: Float = 0) throws {
      guard (-12...12).contains(exposureEV) else { throw Failure.invalidExposure }
      self.id = id
      self.enabled = enabled
      self.exposureEV = exposureEV == 0 ? 0 : exposureEV
    }

    private enum CodingKeys: String, CodingKey { case id, enabled, exposureEV }

    public init(from decoder: Decoder) throws {
      try RecipeCoding.requireKeys(decoder, ["id", "enabled", "exposureEV"])
      let fields = try decoder.container(keyedBy: CodingKeys.self)
      try self.init(id: fields.decode(UUID.self, forKey: .id), enabled: fields.decode(Bool.self, forKey: .enabled),
                    exposureEV: fields.decode(Float.self, forKey: .exposureEV))
    }
  }

  public static let maximumCorrectors = 64
  private let schemaVersion = 1
  public let correctors: [Corrector]
  public let output: DevelopmentSceneOutputStateV1.Version

  public init(correctors: [Corrector], output: DevelopmentSceneOutputStateV1.Version) throws {
    guard (1...Self.maximumCorrectors).contains(correctors.count), Set(correctors.map(\.id)).count == correctors.count else {
      throw Failure.invalidNodes
    }
    var prefix = 0.0
    for node in correctors where node.enabled {
      prefix += Double(node.exposureEV)
      guard (-12...12).contains(prefix) else { throw Failure.invalidExposure }
    }
    self.correctors = correctors
    self.output = output
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, correctors, output }

  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder, ["schemaVersion", "correctors", "output"])
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    guard try fields.decode(Int.self, forKey: .schemaVersion) == 1 else { throw Failure.unsupportedSchema }
    var nodes = try fields.nestedUnkeyedContainer(forKey: .correctors)
    var correctors: [Corrector] = []
    while !nodes.isAtEnd {
      guard correctors.count < Self.maximumCorrectors else { throw Failure.invalidNodes }
      correctors.append(try nodes.decode(Corrector.self))
    }
    try self.init(correctors: correctors, output: fields.decode(DevelopmentSceneOutputStateV1.Version.self, forKey: .output))
  }

  // v1 has only serial exposure: when another operation is admitted, it needs an explicit stage and order.
  public func finalExposureEV() throws -> Float { try exposureEV(through: nil) }

  public func exposureEV(through nodeID: UUID) throws -> Float { try exposureEV(through: Optional(nodeID)) }

  private func exposureEV(through nodeID: UUID?) throws -> Float {
    let end: [Corrector].Index
    if let nodeID {
      guard let index = correctors.firstIndex(where: { $0.id == nodeID }) else { throw Failure.unknownNode }
      end = index + 1
    } else {
      end = correctors.endIndex
    }
    let sum = correctors[..<end].reduce(0.0) { $0 + ($1.enabled ? Double($1.exposureEV) : 0) }
    guard (-12...12).contains(sum) else { throw Failure.invalidExposure }
    return Float(sum)
  }
}
