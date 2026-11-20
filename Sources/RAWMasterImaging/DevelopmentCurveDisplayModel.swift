import Foundation
import RAWMasterCore

/// CPU control-function display only: normalized x/y, not the group's gamma/LUT/pixel response.
/// No image, GPU resource, renderer context, or mutable shared state is retained.
public struct DevelopmentCurveDisplayModel: Sendable {
  public let algorithm: DevelopmentCurvesAlgorithmV3
  private let curve: DevelopmentCurve
  // Immutable value snapshots of the EXISTING F32 evaluator, not a second spline implementation.
  // Store arrays directly so Sendable is checked without changing the frozen engine's Model type.
  private let x, y, b, c, d, second: [Float]

  public init(curve: DevelopmentCurve, algorithm: DevelopmentCurvesAlgorithmV3) throws {
    try curve.validate()
    self.curve = curve; self.algorithm = algorithm
    switch algorithm {
    case .legacyPCHIPV1:
      x = []; y = []; b = []; c = []; d = []; second = []
    case .naturalCubicGamma512LumaV1:
      let model = try DevelopmentNaturalCubicCurvesV1.model(curve)
      x = model.x; y = model.y; b = model.b; c = model.c; d = model.d; second = model.second
    }
  }

  public func matches(_ curve: DevelopmentCurve) -> Bool { self.curve == curve }

  public func value(at coordinate: Double) throws -> Double {
    guard coordinate.isFinite else { throw DevelopmentV3Error.unrepresentableParameters }
    switch algorithm {
    case .legacyPCHIPV1: return try curve.value(at: coordinate)
    case .naturalCubicGamma512LumaV1:
      let input = Float(coordinate)
      guard input.isFinite else { throw DevelopmentV3Error.unrepresentableParameters }
      let model = DevelopmentNaturalCubicCurvesV1.Model(x:x, y:y, b:b, c:c, d:d, second:second)
      return Double(try DevelopmentNaturalCubicCurvesV1.evaluate(model,input))
    }
  }
}
