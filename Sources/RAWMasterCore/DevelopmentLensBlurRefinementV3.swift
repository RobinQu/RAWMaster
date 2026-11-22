import Foundation

public enum DevelopmentLensBlurRefinementModeV3: String, Codable, Sendable {
  case focus, blur
}

/// Current brush settings are recipe state; each committed stroke owns an immutable snapshot.
public struct DevelopmentLensBlurRefinementBrushV3: Codable, Equatable, Sendable {
  public var amount, size, feather, flow: Double
  /// Nil preserves the first refinement recipe shape and means disabled.
  public var autoMask: Bool?
  public init(amount: Double = 1, size: Double = 0.08, feather: Double = 0.3, flow: Double = 0.5, autoMask: Bool? = nil) {
    self.amount=amount;self.size=size;self.feather=feather;self.flow=flow;self.autoMask=autoMask
  }
  public func validate() throws {
    try DevelopmentV3Validation.range([amount,size,feather,flow],0...1)
    guard size >= DevelopmentLocalEditLimits.minimumRadiusInShortEdge else { throw EditingError.invalidRecipe }
  }
}

public struct DevelopmentLensBlurRefinementStrokeV3: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var mode: DevelopmentLensBlurRefinementModeV3
  public var stroke: DevelopmentStroke
  public var feather, flow: Double
  public var autoMask: Bool?
  public init(id: UUID = UUID(), mode: DevelopmentLensBlurRefinementModeV3, stroke: DevelopmentStroke,
              feather: Double = 0.3, flow: Double = 0.5, autoMask: Bool? = nil) {
    self.id=id;self.mode=mode;self.stroke=stroke;self.feather=feather;self.flow=flow;self.autoMask=autoMask
  }
  public func validate() throws {
    try stroke.validate();try DevelopmentV3Validation.range([feather,flow],0...1)
  }
  public static func validateStrokes(_ strokes: [Self]) throws {
    guard strokes.count <= 64 else { throw EditingError.invalidRecipe }
    var ids=Set<UUID>(),points=0
    for item in strokes {
      try item.validate()
      guard ids.insert(item.id).inserted,
        points <= DevelopmentLocalEditLimits.maximumTotalPoints-item.stroke.points.count else { throw EditingError.invalidRecipe }
      points += item.stroke.points.count
    }
  }
}
