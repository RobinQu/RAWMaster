import CryptoKit
import Foundation

public enum DevelopmentSemanticTarget: String, Codable, CaseIterable, Sendable {
  case subject, background, instance, object, sky, water, brush

  public var title: String {
    switch self {
    case .subject: "主体"
    case .background: "背景"
    case .instance: "前景实例"
    case .object: "点选或框选物体"
    case .sky: "天空"
    case .water: "水面"
    case .brush: "画笔"
    }
  }
}

/// Source-space Gray8 coverage is frozen in subjectPNG. Neither an installed model nor a cache
/// reference is required to reopen a photo or export it on another machine.
public struct DevelopmentSemanticMaskSnapshot: Codable, Equatable, Sendable {
  public let source: DevelopmentLocalEditSourceBinding
  public let target: DevelopmentSemanticTarget
  public let generator: String
  /// The neutral input decoder used for this frozen selection. Older snapshots omit its identity.
  public let analysisDecoder: String?
  public let modelHashes: [String]
  /// A point, or opposing corners of a box, in top-left oriented source coordinates.
  public let prompt: [DevelopmentSourcePoint]
  public let width, height: Int
  public let pngSHA256: String
  private var manualRefinement: Bool?
  public var wasRefined: Bool { manualRefinement == true }

  public init(
    source: DevelopmentLocalEditSourceBinding, target: DevelopmentSemanticTarget, generator: String,
    modelHashes: [String] = [], prompt: [DevelopmentSourcePoint] = [], width: Int, height: Int,
    png: Data, wasRefined: Bool = false, analysisDecoder: String? = nil
  ) {
    manualRefinement = wasRefined ? true : nil
    self.source = source
    self.target = target
    self.generator = generator
    self.analysisDecoder = analysisDecoder
    self.modelHashes = modelHashes
    self.prompt = prompt
    self.width = width
    self.height = height
    self.pngSHA256 = Self.digest(png)
  }
  public static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
  public func validate(png: Data) throws {
    try source.validate()
    guard (1...1536).contains(width), (1...1536).contains(height),
      (1...96).contains(generator.count), analysisDecoder.map({ (1...96).contains($0.count) }) ?? true,
      modelHashes.count <= 4,
      modelHashes.allSatisfy(EditingFingerprint.isSHA256), prompt.count <= 2,
      [.instance, .object].contains(target) ? !prompt.isEmpty : prompt.isEmpty,
      png.count >= 33,
      png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82]),
      png[png.startIndex + 24] == 8, png[png.startIndex + 25] == 0, Self.digest(png) == pngSHA256
    else { throw EditingError.invalidRecipe }
    func int32(_ offset: Int) -> Int {
      png[(png.startIndex + offset)..<(png.startIndex + offset + 4)].reduce(0) {
        ($0 << 8) | Int($1)
      }
    }
    guard int32(16) == width, int32(20) == height else { throw EditingError.invalidRecipe }
    try prompt.forEach { try $0.validate() }
  }
}

extension DevelopmentMaskLayerV3 {
  public static func validateSource(_ layers: [Self], expected: DevelopmentLocalEditSourceBinding)
    throws
  {
    guard layers.allSatisfy({ $0.semanticSnapshot.map { $0.source == expected } ?? true }) else {
      throw DevelopmentAdjustmentCommandError.mismatchedSource
    }
  }
}
