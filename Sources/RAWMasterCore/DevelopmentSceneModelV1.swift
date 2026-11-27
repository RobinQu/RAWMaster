import Foundation

/// Deterministic, full-image model stages that run inside one development render call.
///
/// These are deliberately *not* a generative-AI surface: a stage names a versioned model,
/// a bounded amount, and a fixed input/output contract. There are no prompts, candidates or
/// patch versions here. FLUX/Seedream candidate generation stays in `RAWMasterAI` and always
/// returns separate low-resolution artifacts.
public struct DevelopmentSceneModelStageV1: Codable, Equatable, Sendable, Identifiable {
  public enum Failure: Error, Equatable {
    case unsupportedStage, invalidAmount, invalidOrder, invalidScale, duplicateModel, invalidModel
  }

  public enum Kind: String, Codable, CaseIterable, Sendable {
    case denoise, superResolution, segmentation

    fileprivate var rank: Int {
      switch self {
      case .denoise: return 0
      case .superResolution: return 1
      case .segmentation: return 2
      }
    }
  }

  public enum Configuration: Equatable, Sendable {
    case denoise(model: DevelopmentAIDenoiseV1.Model, amount: Int)
    case superResolution(DevelopmentSuperResolutionV1)
    case segmentation(DevelopmentSceneSegmentationModelV1)
  }

  public static let inputContract = "scene-linear-ap1-f32-premultiplied-v1"
  public static let maximumStages = 4

  public let id: UUID
  public let configuration: Configuration

  public init(id: UUID = UUID(), configuration: Configuration) {
    self.id = id
    self.configuration = configuration
  }

  public static func denoise(_ model: DevelopmentAIDenoiseV1.Model = .photoVGG7Chroma,
                             amount: Int = 50, id: UUID = UUID()) -> Self {
    .init(id: id, configuration: .denoise(model: model, amount: amount))
  }

  public static func superResolution(_ model: DevelopmentSuperResolutionV1 = .photoUpconv7,
                                     id: UUID = UUID()) -> Self {
    .init(id: id, configuration: .superResolution(model))
  }

  public static func segmentation(_ model: DevelopmentSceneSegmentationModelV1 = .subject,
                                  id: UUID = UUID()) -> Self {
    .init(id: id, configuration: .segmentation(model))
  }

  public var kind: Kind {
    switch configuration {
    case .denoise: return .denoise
    case .superResolution: return .superResolution
    case .segmentation: return .segmentation
    }
  }

  public var scale: Int { kind == .superResolution ? 2 : 1 }

  public var outputContract: String {
    kind == .segmentation ? "coverage-r32f-v1" : "scene-linear-ap1-f32-premultiplied-v1"
  }

  public var modelIdentity: String {
    switch configuration {
    case .denoise(let model, _): return model.rawValue
    case .superResolution(let model): return model.rawValue
    case .segmentation(let model): return model.rawValue
    }
  }

  public func validate() throws {
    switch configuration {
    case .denoise(let model, let amount):
      guard (0...100).contains(amount) else { throw Failure.invalidAmount }
      // Scene-linear AP1 is already demosaiced; mosaic/RAW-domain or DNG-output models belong
      // to the legacy RAW renderer and may not silently run here.
      guard model.usesFullPhotoChroma, !model.requiresMosaic, !model.usesRAWInput else {
        throw Failure.invalidModel
      }
    case .superResolution(let model):
      guard model == .photoUpconv7 else { throw Failure.invalidModel }
    case .segmentation:
      break
    }
  }

  private enum CodingKeys: String, CodingKey { case id, kind, model, amount }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    id = try fields.decode(UUID.self, forKey: .id)
    let kind = try fields.decode(Kind.self, forKey: .kind)
    let model = try fields.decode(String.self, forKey: .model)
    switch kind {
    case .denoise:
      guard let model = DevelopmentAIDenoiseV1.Model(rawValue: model) else { throw Failure.invalidModel }
      configuration = .denoise(model: model, amount: try fields.decode(Int.self, forKey: .amount))
    case .superResolution:
      guard let model = DevelopmentSuperResolutionV1(rawValue: model) else { throw Failure.invalidModel }
      configuration = .superResolution(model)
    case .segmentation:
      guard let model = DevelopmentSceneSegmentationModelV1(rawValue: model) else { throw Failure.invalidModel }
      configuration = .segmentation(model)
    }
    try validate()
  }

  public func encode(to encoder: Encoder) throws {
    var fields = encoder.container(keyedBy: CodingKeys.self)
    try fields.encode(id, forKey: .id)
    try fields.encode(kind, forKey: .kind)
    try fields.encode(modelIdentity, forKey: .model)
    if case .denoise(_, let amount) = configuration { try fields.encode(amount, forKey: .amount) }
  }
}

/// A bounded, ordered model prefix. Denoise runs first, optional 2x super-resolution runs once,
/// and segmentation produces coverage at the final image size.
public struct DevelopmentSceneModelProgramV1: Codable, Equatable, Sendable {
  public let stages: [DevelopmentSceneModelStageV1]

  public init(stages: [DevelopmentSceneModelStageV1] = []) throws {
    self.stages = stages
    try validate()
  }

  private enum CodingKeys: String, CodingKey { case stages }

  public init(from decoder: Decoder) throws {
    let fields = try decoder.container(keyedBy: CodingKeys.self)
    stages = try fields.decode([DevelopmentSceneModelStageV1].self, forKey: .stages)
    try validate()
  }

  public func validate() throws {
    guard stages.count <= DevelopmentSceneModelStageV1.maximumStages else {
      throw DevelopmentSceneModelStageV1.Failure.unsupportedStage
    }
    guard Set(stages.map(\.id)).count == stages.count else {
      throw DevelopmentSceneModelStageV1.Failure.duplicateModel
    }
    var previousRank = -1, superResolutions = 0
    for stage in stages {
      try stage.validate()
      guard stage.kind.rank >= previousRank else {
        throw DevelopmentSceneModelStageV1.Failure.invalidOrder
      }
      previousRank = stage.kind.rank
      if stage.kind == .superResolution {
        superResolutions += 1
        guard superResolutions == 1 else { throw DevelopmentSceneModelStageV1.Failure.duplicateModel }
      }
    }
  }

  public var scale: Int { stages.contains { $0.kind == .superResolution } ? 2 : 1 }
  public var coverageStages: [DevelopmentSceneModelStageV1] {
    stages.filter { $0.kind == .segmentation }
  }
}

/// Stable identities for deterministic segmentation providers. The suffix pins the native
/// mask algorithm; the model prefix names the ONNX artifact.
public enum DevelopmentSceneSegmentationModelV1: String, Codable, CaseIterable, Sendable {
  case subject = "isnet-general@mask-ai-native-v1"
  case landscape = "efficientvit-seg-b2-ade20k@mask-ai-native-v1"
  case people = "selfie-multiclass@mask-ai-native-v1"
}

public extension DevelopmentSceneModelProgramV1 {
  /// Maps the scene-compatible parts of a legacy recipe into the deterministic model prefix.
  /// RAW-domain/mosaic denoisers and mask candidates are intentionally not inferred here.
  static func derived(from adjustments: DevelopmentAdjustmentsV3) throws -> Self? {
    var stages: [DevelopmentSceneModelStageV1] = []
    if let denoise = adjustments.aiDenoise, denoise.model == .photoVGG7Chroma {
      stages.append(.denoise(denoise.model, amount: denoise.amount))
    }
    if let superResolution = adjustments.superResolution {
      stages.append(.superResolution(superResolution))
    }
    return stages.isEmpty ? nil : try .init(stages: stages)
  }
}
