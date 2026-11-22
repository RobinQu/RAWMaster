import Foundation

/// RawMaster-owned parametric tone mapping. The four amounts and three split controls are stored
/// independently of the point editor; this is not a claim about Adobe's proprietary curve math.
public struct DevelopmentParametricCurveV3: Codable, Equatable, Sendable {
  public var highlights, lights, darks, shadows: Double
  public var split1, split2, split3: Double

  public init(highlights: Double = 0, lights: Double = 0, darks: Double = 0, shadows: Double = 0,
              split1: Double = 0.25, split2: Double = 0.5, split3: Double = 0.75) {
    self.highlights = highlights; self.lights = lights; self.darks = darks; self.shadows = shadows
    self.split1 = split1; self.split2 = split2; self.split3 = split3
  }

  public var isActive: Bool { highlights != 0 || lights != 0 || darks != 0 || shadows != 0 }

  public func validate() throws {
    try DevelopmentV3Validation.range([highlights,lights,darks,shadows],-100...100)
    try DevelopmentV3Validation.range([split1,split2,split3],0...1)
    guard split1 < split2, split2 < split3 else { throw EditingError.invalidRecipe }
  }

  /// Convert to the existing validated point/LUT transport. Sixteen deterministic samples retain
  /// the current renderer's PCHIP path while the parametric model remains independently versioned.
  public func pointCurve() throws -> DevelopmentCurve {
    try validate()
    let centers = [split1/2, (split1+split2)/2, (split2+split3)/2, (split3+1)/2]
    let widths = [split1, split2-split1, split3-split2, 1-split3].map { max(0.04,$0*0.65) }
    let amounts = [shadows,darks,lights,highlights]
    let points = (0..<16).map { index -> DevelopmentCurvePoint in
      let x = Double(index)/15
      var delta = 0.0
      for region in 0..<4 {
        let z = (x-centers[region])/widths[region]
        delta += amounts[region]/100*0.16*exp(-0.5*z*z)
      }
      return .init(x:x,y:min(1,max(0,x+delta)))
    }
    let curve = DevelopmentCurve(points:points)
    try curve.validate()
    return curve
  }
}
