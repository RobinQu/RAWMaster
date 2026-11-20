import Foundation

public struct DevelopmentContinuousRectV3: Equatable, Sendable {
  public let x, y, width, height: Double
  public init(x: Double, y: Double, width: Double, height: Double) { self.x = x; self.y = y; self.width = width; self.height = height }
}
/// Column-vector, top-left pixel-space matrices. The intermediate clips are part of the contract:
/// Imaging must consume them together with these matrices, not recompute an independent projection.
public struct DevelopmentProjectiveDescriptorV3: Equatable, Sendable {
  public let prePerspectiveMatrix, perspectiveMatrix, forwardMatrix, inverseMatrix: [Double]
  public let intermediateClip, perspectiveTrim, finalCrop: DevelopmentContinuousRectV3
  public let outputSize: DevelopmentPixelSize
  static func point(_ m: [Double], _ x: Double, _ y: Double) throws -> (Double,Double) {
    let p = DevelopmentRGBMatrixV3.apply(m,[x,y,1])
    guard p.allSatisfy(\.isFinite), p[2] >= 1e-4 else { throw DevelopmentGeometryMappingError.invalidExtent }
    return (p[0]/p[2],p[1]/p[2])
  }
}
extension DevelopmentGeometryV3 {
  func projectiveMapping(sourceSize: DevelopmentPixelSize) throws -> DevelopmentGeometryMappingV3 {
    var w = Double(sourceSize.width), h = Double(sourceSize.height), a = DevelopmentAffineV3.identity
    // Keep the existing adjustV3 quarter→flip→straighten/inscribed trim order unchanged.
    for _ in 0..<clockwiseQuarterTurns { a = a.followed(by:.init(a:0,b:1,c:-1,d:0,tx:h,ty:0)); swap(&w,&h) }
    if flipHorizontal { a = a.followed(by:.init(a:-1,b:0,c:0,d:1,tx:w,ty:0)) }
    if flipVertical { a = a.followed(by:.init(a:1,b:0,c:0,d:-1,tx:0,ty:h)) }
    if straightenDegrees != 0 {
      let angle = straightenDegrees * .pi/180, c = cos(angle), s = sin(angle)
      let size = Self.inscribedSize(width:w,height:h,angle:abs(angle))
      a = a.followed(by:.init(a:c,b:-s,c:s,d:c,tx:size.0/2-c*w/2-s*h/2,ty:size.1/2+s*w/2-c*h/2))
      w = size.0; h = size.1
    }
    guard w.isFinite, h.isFinite, w > 0, h > 0 else { throw DevelopmentGeometryMappingError.invalidExtent }
    let short = min(w,h), v = verticalPerspective * .pi/180, horizontal = horizontalPerspective * .pi/180
    let cv = cos(v), sv = sin(v), ch = cos(horizontal), sh = sin(horizontal)
    let p = [ch,sh*sv,0,0,cv,0,-sh/2,ch*sv/2,1]
    let u = [1/short,0,-w/(2*short),0,1/short,-h/(2*short),0,0,1]
    let un = [short,0,w/2,0,short,h/2,0,0,1]
    let perspective = DevelopmentRGBMatrixV3.multiply(un,DevelopmentRGBMatrixV3.multiply(p,u))
    let corners = try [(0.0,0.0),(w,0),(w,h),(0,h)].map { try DevelopmentProjectiveDescriptorV3.point(perspective,$0.0,$0.1) }
    var lambda = Double.infinity
    for i in 0..<4 {
      let q = corners[i], r = corners[(i+1)%4], dx = r.0-q.0, dy = r.1-q.1
      let aa = dy, bb = -dx, cc = aa*(q.0-w/2)+bb*(q.1-h/2)
      let denominator = abs(aa)*w/2+abs(bb)*h/2
      guard cc.isFinite, cc > 0, denominator.isFinite, denominator > 0 else { throw DevelopmentGeometryMappingError.invalidExtent }
      lambda = min(lambda,cc/denominator)
    }
    let tw = lambda*w, th = lambda*h
    guard lambda.isFinite, lambda > 0, tw.isFinite, th.isFinite else { throw DevelopmentGeometryMappingError.invalidExtent }
    let trimX = (w-tw)/2, trimY = (h-th)/2
    let minX = ceil(tw*crop.x), maxX = floor(tw*(crop.x+crop.width))
    let minBottom = ceil(th*(1-crop.y-crop.height)), maxBottom = floor(th*(1-crop.y))
    let outputW = maxX-minX, outputH = maxBottom-minBottom, top = th-maxBottom
    guard outputW.isFinite, outputH.isFinite, outputW >= 1, outputH >= 1,
      outputW <= Double(DevelopmentLocalEditLimits.maximumSourceDimension), outputH <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) else { throw DevelopmentGeometryMappingError.invalidExtent }
    let pre = [a.a,a.c,a.tx,a.b,a.d,a.ty,0,0,1]
    let translation = [1.0,0,-trimX-minX,0,1,-trimY-top,0,0,1]
    let matrix = DevelopmentRGBMatrixV3.multiply(translation,DevelopmentRGBMatrixV3.multiply(perspective,pre))
    let inverse = try DevelopmentRGBMatrixV3.inverse(matrix)
    guard matrix.allSatisfy(\.isFinite), inverse.allSatisfy(\.isFinite) else { throw DevelopmentGeometryMappingError.invalidExtent }
    let descriptor = DevelopmentProjectiveDescriptorV3(prePerspectiveMatrix:pre,perspectiveMatrix:perspective,forwardMatrix:matrix,inverseMatrix:inverse,
      intermediateClip:.init(x:0,y:0,width:w,height:h),perspectiveTrim:.init(x:trimX,y:trimY,width:tw,height:th),
      finalCrop:.init(x:minX,y:top,width:outputW,height:outputH),outputSize:.init(width:Int(outputW),height:Int(outputH)))
    let toPlane = DevelopmentRGBMatrixV3.multiply([1,0,-trimX,0,1,-trimY,0,0,1],DevelopmentRGBMatrixV3.multiply(perspective,pre))
    let plane = DevelopmentGeometryCropPlaneV3(width:tw,height:th,forwardMatrix:toPlane,inverseMatrix:try DevelopmentRGBMatrixV3.inverse(toPlane),
      actualRasterRect:.init(x:minX,y:top,width:outputW,height:outputH))
    return .init(sourceSize:sourceSize,descriptor:descriptor,cropPlane:plane)
  }
}
