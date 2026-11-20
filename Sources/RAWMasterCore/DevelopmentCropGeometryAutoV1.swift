// Version-1 horizon-derived crop Auto; native qualification is tracked separately.
import Foundation
public enum DevelopmentCropGeometryAutoV1 {
  public static func supports(_ geometry: DevelopmentGeometryV3) -> Bool {
    geometry.verticalPerspective == 0 && geometry.horizontalPerspective == 0
  }
  public static func fitted(_ crop: NormalizedCrop, ratio: Double?, plane: DevelopmentContinuousRectV3) throws -> NormalizedCrop {
    guard [plane.width,plane.height,crop.x,crop.y,crop.width,crop.height].allSatisfy(\.isFinite), plane.width > 0, plane.height > 0,
      crop.x >= 0,crop.y >= 0,crop.width > 0,crop.height > 0,crop.x+crop.width <= 1+1e-12,crop.y+crop.height <= 1+1e-12 else { throw EditingError.invalidRecipe }
    guard let ratio else { return crop }
    guard ratio.isFinite,ratio > 0 else { throw EditingError.invalidRecipe }
    let width=min(crop.width*plane.width,crop.height*plane.height*ratio), height=width/ratio
    let w=width/plane.width,h=height/plane.height
    return .init(x:crop.x+(crop.width-w)/2,y:crop.y+(crop.height-h)/2,width:w,height:h)
  }
  public static func horizonDifference(_ a: Double, _ b: Double) -> Double {
    let x=(a-b).truncatingRemainder(dividingBy:180)
    return x >= 90 ? x-180 : (x < -90 ? x+180:x)
  }
  /// Vision CGAffine linear part [a,b,c,d], image bottom-left coordinates; output Core top-left angle.
  /// Coordinate convention/sign must pass both synthetic D4 and actual natural-photo known-rotation qualification.
  public static func absoluteStraighten(bottomLeftLinear v: [Double], late: DevelopmentD4OrientationV3) throws -> Double {
    guard v.count == 4,v.allSatisfy(\.isFinite) else { throw EditingError.invalidRecipe }
    let a=v[0],b=v[1],c=v[2],d=v[3],eps=1e-5
    guard abs(a*d-b*c-1) <= eps, abs(a*a+b*b-1) <= eps,
      abs(c*c+d*d-1) <= eps, abs(a*c+b*d) <= eps else { throw EditingError.invalidRecipe }
    // F*V*F changes image-bottom-left to oriented-top-left; late^-1 * Vtop * late
    // represents the correction before late-D4 without altering that user's D4 value.
    let m=late.normalizedMatrix, l=[m[0],m[1],m[3],m[4]], t=[a,-c,-b,d]
    func mul(_ x:[Double],_ y:[Double])->[Double] { [x[0]*y[0]+x[1]*y[2],x[0]*y[1]+x[1]*y[3],x[2]*y[0]+x[3]*y[2],x[2]*y[1]+x[3]*y[3]] }
    let r=mul(mul([l[0],l[2],l[1],l[3]],t),l)
    return horizonDifference(atan2(r[1],r[0])*180/Double.pi,0)
  }
  public static func candidate(baseline: DevelopmentGeometryV3,sourceSize: DevelopmentPixelSize,
                               absoluteDegrees: Double,aspectRatio: Double?) throws -> DevelopmentGeometryV3 {
    try baseline.validate();guard supports(baseline),absoluteDegrees.isFinite else { throw EditingError.invalidRecipe }
    var value=baseline;value.straightenDegrees=absoluteDegrees
    var planeOnly=value;planeOnly.crop = .init()
    let plane=try planeOnly.mapping(sourceSize:sourceSize).cropPlane
    value.crop=try fitted(baseline.crop,ratio:aspectRatio,plane:plane.rect)
    try value.validate();_=try value.mapping(sourceSize:sourceSize);return value
  }
}
