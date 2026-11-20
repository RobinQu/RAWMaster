import Foundation

/// Continuous, top-left plane after all geometry/trim and BEFORE the user's final crop.
/// Raster rect origins preserve inward-rounding offsets, including fractional top-edge loss.
public struct DevelopmentGeometryCropPlaneV3: Equatable, Sendable {
  public let rect: DevelopmentContinuousRectV3
  public let forwardMatrix, inverseMatrix: [Double]
  public let identityRasterRect, actualRasterRect: DevelopmentContinuousRectV3
  public var identityRasterSize: DevelopmentPixelSize {
    .init(width:Int(identityRasterRect.width),height:Int(identityRasterRect.height))
  }
  init(width: Double, height: Double, forwardMatrix: [Double], inverseMatrix: [Double], actualRasterRect: DevelopmentContinuousRectV3) {
    rect = .init(x:0,y:0,width:width,height:height)
    self.forwardMatrix = forwardMatrix; self.inverseMatrix = inverseMatrix
    identityRasterRect = .init(x:0,y:height-floor(height),width:floor(width),height:floor(height))
    self.actualRasterRect = actualRasterRect
  }
}
