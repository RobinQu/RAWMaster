import Foundation

/// Explicit V3 curve semantics. Missing legacy key is never an implicit upgrade.
public enum DevelopmentCurvesAlgorithmV3: String, Codable, Hashable, Sendable {
  case legacyPCHIPV1 = "legacy-pchip-v1"
  case naturalCubicGamma512LumaV1 = "natural-cubic-gamma512-luma-v1"
}

extension DevelopmentCurvesV3 {
  /// Opening/replaying a saved recipe never calls this. A deliberate new control edit selects
  /// the current display/math contract instead of leaving the new algorithm unreachable.
  public func forDirectUserEdit() -> Self {
    var value=self;value.enabled=true;value.algorithm = .naturalCubicGamma512LumaV1;return value
  }
}
