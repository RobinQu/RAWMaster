import Foundation

public enum DevelopmentLateOperationV3: Sendable { case rotateClockwise, flipHorizontal, flipVertical }

/// One canonical element of D4. Operations act AFTER the complete pre-existing trim/projection.
public enum DevelopmentD4OrientationV3: String, Codable, CaseIterable, Sendable {
  case identity, rotate90, rotate180, rotate270, flipHorizontal, flipVertical, transpose, transverse
  var normalizedMatrix: [Double] {
    switch self {
    case .identity: return [1,0,0,0,1,0,0,0,1]
    case .rotate90: return [0,-1,1,1,0,0,0,0,1]
    case .rotate180: return [-1,0,1,0,-1,1,0,0,1]
    case .rotate270: return [0,1,0,-1,0,1,0,0,1]
    case .flipHorizontal: return [-1,0,1,0,1,0,0,0,1]
    case .flipVertical: return [1,0,0,0,-1,1,0,0,1]
    case .transpose: return [0,1,0,1,0,0,0,0,1]
    case .transverse: return [0,-1,1,-1,0,1,0,0,1]
    }
  }
  public var isReflection: Bool { let m = normalizedMatrix; return m[0]*m[4]-m[1]*m[3] < 0 }
  public func composeAfter(_ current: Self) -> Self {
    let product = DevelopmentRGBMatrixV3.multiply(normalizedMatrix,current.normalizedMatrix)
    // Closed exact {-1,0,1} multiplication; never approximate or infer a second representation.
    return Self.allCases.first { $0.normalizedMatrix == product }!
  }
  func pixelTransform(width: Double,height: Double) -> (matrix:[Double],width:Double,height:Double) {
    let n = normalizedMatrix, swap = n[0] == 0
    let w = swap ? height:width, h = swap ? width:height
    return ([n[0],n[1],n[2]*w,n[3],n[4],n[5]*h,0,0,1],w,h)
  }
}

public struct DevelopmentLateOrientationV3: Codable, Equatable, Sendable {
  public var version: Int
  public var orientation: DevelopmentD4OrientationV3
  public init(version: Int = 1,orientation: DevelopmentD4OrientationV3 = .identity) { self.version = version; self.orientation = orientation }
  public func validate() throws { guard version == 1 else { throw EditingError.invalidRecipe } }
  private enum CodingKeys: String,CodingKey { case version,orientation }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["version","orientation"])
    let c = try decoder.container(keyedBy:CodingKeys.self)
    version = try c.decode(Int.self,forKey:.version); orientation = try c.decode(DevelopmentD4OrientationV3.self,forKey:.orientation)
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(version,forKey:.version); try c.encode(orientation,forKey:.orientation)
  }
}

extension DevelopmentGeometryV3 {
  /// Compose a view-space operation and transport the logical crop with it. Old pre-geometry
  /// parameters remain unchanged; the caller commits this one returned geometry atomically.
  public func applyingLateOperation(_ operation: DevelopmentLateOperationV3) throws -> Self {
    try validate(); var result = self
    let element: DevelopmentD4OrientationV3
    switch operation {
    case .rotateClockwise:
      element = .rotate90
      result.crop = .init(x:1-crop.y-crop.height,y:crop.x,width:crop.height,height:crop.width)
    case .flipHorizontal:
      element = .flipHorizontal
      result.crop = .init(x:1-crop.x-crop.width,y:crop.y,width:crop.width,height:crop.height)
    case .flipVertical:
      element = .flipVertical
      result.crop = .init(x:crop.x,y:1-crop.y-crop.height,width:crop.width,height:crop.height)
    }
    result.version = .projectiveV3_1
    result.lateOrientation = .init(orientation:element.composeAfter(lateOrientation.orientation))
    try result.validate(); return result
  }
  func lateMapping(sourceSize: DevelopmentPixelSize) throws -> DevelopmentGeometryMappingV3 {
    var original = self; original.lateOrientation = .init(); original.crop = .init()
    let base = try original.mapping(sourceSize:sourceSize), plane = base.cropPlane
    let late = lateOrientation.orientation.pixelTransform(width:plane.rect.width,height:plane.rect.height)
    let toPlane = DevelopmentRGBMatrixV3.multiply(late.matrix,plane.forwardMatrix)
    let w = late.width, h = late.height
    let minX = ceil(w*crop.x), maxX = floor(w*(crop.x+crop.width))
    let minBottom = ceil(h*(1-crop.y-crop.height)), maxBottom = floor(h*(1-crop.y))
    let outputW = maxX-minX, outputH = maxBottom-minBottom, top = h-maxBottom
    guard outputW.isFinite, outputH.isFinite, outputW >= 1, outputH >= 1 else { throw DevelopmentGeometryMappingError.invalidExtent }
    let matrix = DevelopmentRGBMatrixV3.multiply([1,0,-minX,0,1,-top,0,0,1],toPlane)
    let inverse = try DevelopmentRGBMatrixV3.inverse(matrix)
    let p = base.projective
    let descriptor = DevelopmentProjectiveDescriptorV3(
      prePerspectiveMatrix:p?.prePerspectiveMatrix ?? plane.forwardMatrix,
      perspectiveMatrix:p?.perspectiveMatrix ?? [1,0,0,0,1,0,0,0,1],forwardMatrix:matrix,inverseMatrix:inverse,
      intermediateClip:p?.intermediateClip ?? plane.rect,perspectiveTrim:p?.perspectiveTrim ?? plane.rect,
      finalCrop:.init(x:minX,y:top,width:outputW,height:outputH),outputSize:.init(width:Int(outputW),height:Int(outputH)))
    let newPlane = DevelopmentGeometryCropPlaneV3(width:w,height:h,forwardMatrix:toPlane,
      inverseMatrix:try DevelopmentRGBMatrixV3.inverse(toPlane),actualRasterRect:descriptor.finalCrop)
    return .init(sourceSize:sourceSize,descriptor:descriptor,cropPlane:newPlane)
  }
}
