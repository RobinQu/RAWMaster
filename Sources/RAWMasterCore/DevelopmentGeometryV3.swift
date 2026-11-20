import Foundation

public enum DevelopmentGeometryVersionV3: String, Codable, Sendable { case legacyV1, legacyV2, adjustV3, projectiveV3_1 }
public enum DevelopmentGeometryMappingError: Error, Equatable, Sendable { case invalidExtent, unsupportedPerspectiveMapping, pointOutsideSource }
public struct DevelopmentPixelSize: Equatable, Sendable {
  public let width, height: Int
  public init(width: Int, height: Int) { self.width = width; self.height = height }
  public func validate() throws {
    guard (1...DevelopmentLocalEditLimits.maximumSourceDimension).contains(width),
      (1...DevelopmentLocalEditLimits.maximumSourceDimension).contains(height) else { throw EditingError.invalidRecipe }
  }
}
/// Top-left coordinates on the EXIF-oriented original, before all recipe geometry.
public struct DevelopmentSourcePoint: Codable, Equatable, Sendable {
  public var x, y: Double
  public init(x: Double, y: Double) { self.x = x; self.y = y }
  public func validate() throws { try DevelopmentV3Validation.range([x,y],0...1) }
  private enum CodingKeys: String, CodingKey { case x, y }
  public init(from decoder: Decoder) throws {
    try RecipeCoding.requireKeys(decoder,["x","y"]); let c = try decoder.container(keyedBy:CodingKeys.self)
    x = try c.decode(Double.self,forKey:.x); y = try c.decode(Double.self,forKey:.y); try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self); try c.encode(x,forKey:.x); try c.encode(y,forKey:.y)
  }
}
public struct DevelopmentGeometryV3: Codable, Equatable, Sendable {
  public var version: DevelopmentGeometryVersionV3
  public var straightenDegrees, verticalPerspective, horizontalPerspective: Double
  public var crop: NormalizedCrop
  /// Clockwise quarter turns, applied before flips, straighten/trim and crop in adjustV3.
  public var clockwiseQuarterTurns: Int
  public var flipHorizontal, flipVertical: Bool
  public var lateOrientation: DevelopmentLateOrientationV3
  public init(version: DevelopmentGeometryVersionV3 = .adjustV3, straightenDegrees: Double = 0,
              verticalPerspective: Double = 0, horizontalPerspective: Double = 0, crop: NormalizedCrop = .init(),
              clockwiseQuarterTurns: Int = 0, flipHorizontal: Bool = false, flipVertical: Bool = false,
              lateOrientation: DevelopmentLateOrientationV3 = .init()) {
    self.version = version; self.straightenDegrees = straightenDegrees; self.verticalPerspective = verticalPerspective
    self.horizontalPerspective = horizontalPerspective; self.crop = crop; self.clockwiseQuarterTurns = clockwiseQuarterTurns
    self.flipHorizontal = flipHorizontal; self.flipVertical = flipVertical
    self.lateOrientation = lateOrientation
  }
  public func validate() throws {
    try DevelopmentV3Validation.crop(crop); try DevelopmentV3Validation.range([straightenDegrees],-45...45)
    try DevelopmentV3Validation.range([verticalPerspective,horizontalPerspective],-30...30)
    guard (0...3).contains(clockwiseQuarterTurns) else { throw EditingError.invalidRecipe }
    try lateOrientation.validate()
    guard lateOrientation.orientation == .identity || version == .projectiveV3_1 else { throw EditingError.invalidRecipe }
    if version == .legacyV1 || version == .legacyV2 {
      guard clockwiseQuarterTurns == 0, !flipHorizontal, !flipVertical, verticalPerspective == 0,
        horizontalPerspective == 0 else { throw EditingError.invalidRecipe }
    }
  }
  private enum CodingKeys: String, CodingKey { case version, straightenDegrees, verticalPerspective, horizontalPerspective, crop, clockwiseQuarterTurns, flipHorizontal, flipVertical, lateOrientation }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy:CodingKeys.self)
    try RecipeCoding.requireKeys(decoder,["version","straightenDegrees","verticalPerspective","horizontalPerspective","crop","clockwiseQuarterTurns","flipHorizontal","flipVertical"]+(c.contains(.lateOrientation) ? ["lateOrientation"]:[]))
    version = try c.decode(DevelopmentGeometryVersionV3.self,forKey:.version); straightenDegrees = try c.decode(Double.self,forKey:.straightenDegrees)
    verticalPerspective = try c.decode(Double.self,forKey:.verticalPerspective); horizontalPerspective = try c.decode(Double.self,forKey:.horizontalPerspective)
    crop = try c.decode(NormalizedCrop.self,forKey:.crop); try RecipeCoding.requireKeys(try c.superDecoder(forKey:.crop),["x","y","width","height"])
    clockwiseQuarterTurns = try c.decode(Int.self,forKey:.clockwiseQuarterTurns); flipHorizontal = try c.decode(Bool.self,forKey:.flipHorizontal); flipVertical = try c.decode(Bool.self,forKey:.flipVertical)
    if c.contains(.lateOrientation) { lateOrientation = try c.decode(DevelopmentLateOrientationV3.self,forKey:.lateOrientation) }
    else { lateOrientation = .init() }
    try validate()
  }
  public func encode(to encoder: Encoder) throws {
    try validate(); var c = encoder.container(keyedBy:CodingKeys.self)
    try c.encode(version,forKey:.version); try c.encode(straightenDegrees,forKey:.straightenDegrees); try c.encode(verticalPerspective,forKey:.verticalPerspective); try c.encode(horizontalPerspective,forKey:.horizontalPerspective)
    try c.encode(crop,forKey:.crop); try c.encode(clockwiseQuarterTurns,forKey:.clockwiseQuarterTurns); try c.encode(flipHorizontal,forKey:.flipHorizontal); try c.encode(flipVertical,forKey:.flipVertical)
    if lateOrientation.orientation != .identity { try c.encode(lateOrientation,forKey:.lateOrientation) }
  }
  /// Versioned owned projection; historical adjustV3 still rejects unversioned perspective.
  /// The affine mapping retains the established rotate/inscribed-trim/inward-crop specification.
  public func mapping(sourceSize: DevelopmentPixelSize) throws -> DevelopmentGeometryMappingV3 {
    try validate(); try sourceSize.validate()
    if lateOrientation.orientation != .identity { return try lateMapping(sourceSize:sourceSize) }
    if version == .projectiveV3_1, verticalPerspective != 0 || horizontalPerspective != 0 { return try projectiveMapping(sourceSize:sourceSize) }
    guard verticalPerspective == 0, horizontalPerspective == 0 else { throw DevelopmentGeometryMappingError.unsupportedPerspectiveMapping }
    var w = Double(sourceSize.width), h = Double(sourceSize.height)
    var t = DevelopmentAffineV3.identity
    for _ in 0..<clockwiseQuarterTurns {
      t = t.followed(by:.init(a:0,b:1,c:-1,d:0,tx:h,ty:0)); swap(&w,&h)
    }
    if flipHorizontal { t = t.followed(by:.init(a:-1,b:0,c:0,d:1,tx:w,ty:0)) }
    if flipVertical { t = t.followed(by:.init(a:1,b:0,c:0,d:-1,tx:0,ty:h)) }
    if straightenDegrees != 0 {
      let angle = straightenDegrees * .pi / 180, c = cos(angle), s = sin(angle)
      let size = Self.inscribedSize(width:w,height:h,angle:abs(angle))
      // CI rotates counterclockwise in bottom-left space; this is the equivalent top-left transform.
      t = t.followed(by:.init(a:c,b:-s,c:s,d:c,tx:size.0/2-c*w/2-s*h/2,ty:size.1/2+s*w/2-c*h/2))
      w = size.0; h = size.1
    }
    let rectX = w*crop.x, rectBottom = h*(1-crop.y-crop.height)
    let minX = ceil(rectX), maxX = floor(rectX+w*crop.width)
    let minBottom = ceil(rectBottom), maxBottom = floor(rectBottom+h*crop.height)
    let outputW = maxX-minX, outputH = maxBottom-minBottom, top = h-maxBottom
    guard outputW.isFinite, outputH.isFinite, outputW >= 1, outputH >= 1 else { throw DevelopmentGeometryMappingError.invalidExtent }
    let inverse = try t.inverse()
    let plane = DevelopmentGeometryCropPlaneV3(width:w,height:h,
      forwardMatrix:[t.a,t.c,t.tx,t.b,t.d,t.ty,0,0,1],inverseMatrix:[inverse.a,inverse.c,inverse.tx,inverse.b,inverse.d,inverse.ty,0,0,1],
      actualRasterRect:.init(x:minX,y:top,width:outputW,height:outputH))
    t = t.followed(by:.init(a:1,b:0,c:0,d:1,tx:-minX,ty:-top))
    return .init(sourceSize:sourceSize,outputSize:.init(width:Int(outputW),height:Int(outputH)),transform:t,cropPlane:plane)
  }
  static func inscribedSize(width: Double, height: Double, angle: Double) -> (Double,Double) {
    let s = sin(angle), c = cos(angle), long = max(width,height), short = min(width,height)
    if short <= 2*s*c*long || abs(c-s) < 1e-10 {
      let x = short/2
      return width >= height ? (x/max(s,1e-10),x/c) : (x/c,x/max(s,1e-10))
    }
    let cos2 = c*c-s*s; return ((width*c-height*s)/cos2,(height*c-width*s)/cos2)
  }
}
struct DevelopmentAffineV3: Equatable, Sendable {
  var a,b,c,d,tx,ty: Double
  static let identity = Self(a:1,b:0,c:0,d:1,tx:0,ty:0)
  func point(_ x: Double, _ y: Double) -> (Double,Double) { (a*x+c*y+tx,b*x+d*y+ty) }
  func followed(by q: Self) -> Self {
    .init(a:q.a*a+q.c*b,b:q.b*a+q.d*b,c:q.a*c+q.c*d,d:q.b*c+q.d*d,tx:q.a*tx+q.c*ty+q.tx,ty:q.b*tx+q.d*ty+q.ty)
  }
  func inverse() throws -> Self {
    let det = a*d-b*c
    guard det.isFinite, abs(det) > 1e-12 else { throw DevelopmentGeometryMappingError.invalidExtent }
    return .init(a:d/det,b:-b/det,c:-c/det,d:a/det,tx:(c*ty-d*tx)/det,ty:(b*tx-a*ty)/det)
  }
}
public struct DevelopmentGeometryMappingV3: Equatable, Sendable {
  public let sourceSize, outputSize: DevelopmentPixelSize
  private let transform: DevelopmentAffineV3
  public let projective: DevelopmentProjectiveDescriptorV3?
  public let cropPlane: DevelopmentGeometryCropPlaneV3
  public var forwardMatrix: [Double] { projective?.forwardMatrix ?? [transform.a,transform.c,transform.tx,transform.b,transform.d,transform.ty,0,0,1] }
  public var inverseMatrix: [Double] {
    get throws {
      if let projective { return projective.inverseMatrix }
      let a = try transform.inverse(); return [a.a,a.c,a.tx,a.b,a.d,a.ty,0,0,1]
    }
  }
  init(sourceSize: DevelopmentPixelSize, outputSize: DevelopmentPixelSize, transform: DevelopmentAffineV3, cropPlane: DevelopmentGeometryCropPlaneV3) { self.sourceSize = sourceSize; self.outputSize = outputSize; self.transform = transform; projective = nil; self.cropPlane = cropPlane }
  init(sourceSize: DevelopmentPixelSize, descriptor: DevelopmentProjectiveDescriptorV3, cropPlane: DevelopmentGeometryCropPlaneV3) { self.sourceSize = sourceSize; outputSize = descriptor.outputSize; transform = .identity; projective = descriptor; self.cropPlane = cropPlane }
  public func sourcePoint(fromOutput point: DevelopmentSourcePoint) throws -> DevelopmentSourcePoint {
    try point.validate()
    let p: (Double,Double)
    if let projective { p = try DevelopmentProjectiveDescriptorV3.point(projective.inverseMatrix,point.x*Double(outputSize.width),point.y*Double(outputSize.height)) }
    else { p = try transform.inverse().point(point.x*Double(outputSize.width),point.y*Double(outputSize.height)) }
    guard let result = Self.normalized(p.0/Double(sourceSize.width),p.1/Double(sourceSize.height)) else { throw DevelopmentGeometryMappingError.pointOutsideSource }
    return result
  }
  public func outputPoint(fromSource point: DevelopmentSourcePoint) throws -> DevelopmentSourcePoint? {
    try point.validate()
    let p: (Double,Double)
    if let projective {
      let before = try DevelopmentProjectiveDescriptorV3.point(projective.prePerspectiveMatrix,point.x*Double(sourceSize.width),point.y*Double(sourceSize.height))
      let clip = projective.intermediateClip
      guard before.0 >= -1e-12, before.1 >= -1e-12, before.0 <= clip.width+1e-12, before.1 <= clip.height+1e-12 else { return nil }
      p = try DevelopmentProjectiveDescriptorV3.point(projective.forwardMatrix,point.x*Double(sourceSize.width),point.y*Double(sourceSize.height))
    }
    else { p = transform.point(point.x*Double(sourceSize.width),point.y*Double(sourceSize.height)) }
    return Self.normalized(p.0/Double(outputSize.width),p.1/Double(outputSize.height))
  }
  private static func normalized(_ x: Double, _ y: Double) -> DevelopmentSourcePoint? {
    // Only floating-point roundoff at an exact edge is clamped; clipped source points remain absent.
    guard x.isFinite, y.isFinite, (-1e-12...1+1e-12).contains(x), (-1e-12...1+1e-12).contains(y) else { return nil }
    return .init(x:min(1,max(0,x)),y:min(1,max(0,y)))
  }
}
extension DevelopmentSourcePoint {
  /// Only for coordinates that are still in raw sensor orientation. Canvas coordinates are already
  /// oriented and must NOT call this again. Dimensions swap for EXIF5...8 in the source binding.
  public func applyingEXIFOrientation(_ orientation: Int) throws -> DevelopmentSourcePoint {
    try validate()
    let result: Self
    switch orientation {
    case 1: result = self
    case 2: result = .init(x:1-x,y:y)
    case 3: result = .init(x:1-x,y:1-y)
    case 4: result = .init(x:x,y:1-y)
    case 5: result = .init(x:y,y:x)
    case 6: result = .init(x:1-y,y:x)
    case 7: result = .init(x:1-y,y:1-x)
    case 8: result = .init(x:y,y:1-x)
    default: throw EditingError.invalidRecipe
    }
    try result.validate(); return result
  }
  public func removingEXIFOrientation(_ orientation: Int) throws -> DevelopmentSourcePoint {
    try applyingEXIFOrientation(orientation == 6 ? 8 : (orientation == 8 ? 6 : orientation))
  }
}
