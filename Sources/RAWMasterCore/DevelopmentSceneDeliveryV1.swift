import Foundation

/// An immutable source and recipe, never a display request or assertion that a master already exists.
package struct DevelopmentSceneDeliveryV1: Codable, Equatable, Sendable {
  package enum Failure: Error, Equatable { case invalidSource, unsupportedSchema, unsupportedTarget, invalidVersion }

  package enum Format: String, Codable, CaseIterable, Sendable {
    case avif10, jpeg8, png16

    package var filenameExtension: String {
      switch self {
      case .avif10: return "avif"
      case .jpeg8: return "jpg"
      case .png16: return "png"
      }
    }

    fileprivate var target: DevelopmentSceneOutputStateV1.Target { self == .avif10 ? .hdr2020 : .sdr709 }
  }

  package enum Program: Equatable, Sendable {
    case serial(DevelopmentSceneWorkflowV1), graph(DevelopmentSceneGraphV1)
    package func fingerprint() throws -> String {
      switch self {
      case .serial(let value): return try EditingFingerprint.of(value)
      case .graph(let value): return try EditingFingerprint.of(DevelopmentRecipe(sceneGraph: value))
      }
    }
  }

  package let source: EditingSourceSnapshot
  package let versionID: UUID
  package let program: Program
  package let target: DevelopmentSceneOutputStateV1.Target
  package let format: Format

  package init(source: EditingSourceSnapshot, versionID: UUID, workflow: DevelopmentSceneWorkflowV1,
               target: DevelopmentSceneOutputStateV1.Target, format: Format = .avif10) throws {
    try self.init(source: source, versionID: versionID, program: .serial(workflow), target: target, format: format)
  }

  package init(work: PhotoWork, version: EditingVersion, format: Format, resolvedSource: EditingSourceSnapshot? = nil) throws {
    guard version.workID == work.id, version.source.hasSameIdentity(as: work.source),
          (resolvedSource ?? version.source).hasSameIdentity(as: work.source) else { throw Failure.invalidSource }
    guard version.kind == .development, version.artifact == nil, version.presetAdoptions == nil,
          let id = UUID(uuidString: version.id), let graph = version.recipe.sceneGraph else { throw Failure.invalidVersion }
    try version.recipe.validate()
    try self.init(source: resolvedSource ?? version.source, versionID: id, program: .graph(graph), target: format.target, format: format)
  }

  package func rendition(_ format: Format) throws -> Self {
    try Self.init(source: source, versionID: versionID, program: program, target: format.target, format: format)
  }

  private init(source: EditingSourceSnapshot, versionID: UUID, program: Program,
               target: DevelopmentSceneOutputStateV1.Target, format: Format) throws {
    guard source.byteCount > 0, !source.projectID.isEmpty, !source.assetID.isEmpty,
          source.sourceLocation.isFileURL, EditingFingerprint.isSHA256(source.contentSHA256),
          EditingFingerprint.isSHA256(source.admissionFingerprint) else { throw Failure.invalidSource }
    guard target == format.target else { throw Failure.unsupportedTarget }
    self.source = source; self.versionID = versionID; self.program = program; self.target = target; self.format = format
  }

  private enum CodingKeys: String, CodingKey { case schemaVersion, source, versionID, workflow, sceneRecipe, target, format }

  package init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    let version = try fields.decode(Int.self, forKey: .schemaVersion)
    let keys = ["schemaVersion", "source", "versionID", "target", "format"]
    let program: Program
    switch version {
    case 1:
      try RecipeCoding.requireKeys(decoder, keys + ["workflow"])
      program = .serial(try fields.decode(DevelopmentSceneWorkflowV1.self, forKey: .workflow))
    case 2:
      try RecipeCoding.requireKeys(decoder, keys + ["sceneRecipe"])
      let recipe = try fields.decode(DevelopmentRecipe.self, forKey: .sceneRecipe)
      guard let graph = recipe.sceneGraph else { throw Failure.invalidVersion }
      program = .graph(graph)
    default: throw Failure.unsupportedSchema
    }
    try self.init(source: fields.decode(EditingSourceSnapshot.self, forKey: .source),
      versionID: fields.decode(UUID.self, forKey: .versionID), program: program,
      target: fields.decode(DevelopmentSceneOutputStateV1.Target.self, forKey: .target),
      format: fields.decode(Format.self, forKey: .format))
  }

  package func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    switch program {
    case let .serial(workflow): try fields.encode(1, forKey: .schemaVersion); try fields.encode(workflow, forKey: .workflow)
    case let .graph(graph): try fields.encode(2, forKey: .schemaVersion); try fields.encode(DevelopmentRecipe(sceneGraph: graph), forKey: .sceneRecipe)
    }
    try fields.encode(source, forKey: .source); try fields.encode(versionID, forKey: .versionID)
    try fields.encode(target, forKey: .target); try fields.encode(format, forKey: .format)
  }
}

extension EditingVersion {
  package var isLiveSceneDelivery: Bool { configuration["liveSceneDelivery"] == "v1" }

  /// A live edit gets an identity inside the immutable export receipt. Looking at a photo or
  /// exporting it never inserts a candidate into the photographer's list of saved results.
  package func freezingSceneAppearance(_ activeRecipe: DevelopmentRecipe) throws -> Self {
    guard activeRecipe.sceneGraph != nil, kind == .original || kind == .development else {
      throw DevelopmentSceneDeliveryV1.Failure.invalidVersion
    }
    try activeRecipe.validate()
    if kind == .development, artifact == nil, recipe == activeRecipe { return self }
    let identity = ["scene-delivery-v1", workID, id, source.contentSHA256, source.admissionFingerprint,
                    try EditingFingerprint.of(activeRecipe)]
    var bytes = Array(try EditingFingerprint.digest(of: identity).prefix(16))
    // UUIDv8 reserves the version/variant bits and leaves 122 bits of the content hash.
    bytes[6] = (bytes[6] & 0x0f) | 0x80
    bytes[8] = (bytes[8] & 0x3f) | 0x80
    let identifier = NSUUID(uuidBytes: bytes).uuidString
    return Self(id: identifier, workID: workID, parentVersionID: id, kind: .development,
                source: source, recipe: activeRecipe, configuration: ["liveSceneDelivery": "v1"], createdAt: createdAt)
  }
}
