import Foundation
import RAWMasterCore

/// Planner-only bound for the unchanged rmProjectiveGeometry sampler. Coordinates are CI world
/// coordinates, including when a downstream lazy resize requests a fractional destination tile.
struct DevelopmentProjectiveSourceROIV3 {
  let sourceExtent, outputExtent: CGRect
  let uploadedInverse: [Double]
  let uploadedSourceHeight, uploadedOutputHeight: Double
  let sourceCoordinateError: Double
  let halo: Double

  init(mapping: DevelopmentGeometryMappingV3, sourceExtent: CGRect, outputExtent: CGRect) throws {
    try self.init(inverseMatrix:mapping.inverseMatrix,sourceExtent:sourceExtent,outputExtent:outputExtent)
  }

  /// The same Double→Float conversion performed for the CIKernel float4 uniforms. In particular,
  /// bounds must not use the more precise Core Double inverse instead of the uploaded matrix.
  init(inverseMatrix: [Double], sourceExtent: CGRect, outputExtent: CGRect) throws {
    func valid(_ r: CGRect) -> Bool {
      r.origin == .zero && r.width.isFinite && r.height.isFinite && r.width > 0 && r.height > 0 &&
        r.width <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) &&
        r.height <= Double(DevelopmentLocalEditLimits.maximumSourceDimension) &&
        r.width == floor(r.width) && r.height == floor(r.height)
    }
    guard valid(sourceExtent), valid(outputExtent), inverseMatrix.count == 9 else { throw DevelopmentV3Error.invalidGraph }
    let m = inverseMatrix.map { Double(Float($0)) }
    guard m.allSatisfy(\.isFinite) else { throw DevelopmentV3Error.invalidGraph }
    let hs = Double(Float(sourceExtent.height)), ho = Double(Float(outputExtent.height))
    let w = outputExtent.width, h = outputExtent.height

    // u is Float round-to-nearest unit roundoff. One least *normal* value per operation also
    // covers a flushed subnormal, rather than assuming preservation of subnormal intermediates.
    // dest.coord() conversion: |δx|<=2uW+η, |δy|<=2uH+η. For ho-y include both that
    // conversion and one rounded subtraction. Gamma8 bounds three products/two adds under
    // either FMA contraction or reassociation (and is deliberately larger than gamma5).
    // Metal's fast float division allows 2.5ULP; 16u below exceeds its <=5u relative bound.
    // No relaxed precision/half math is assumed. Positive finite normal denominators are checked.
    let u: Double = 0x1p-24
    let eta = Double(Float.leastNormalMagnitude)
    let dx = 2*u*w+eta, dy = 2*u*h+eta
    let topY = max(abs(ho),abs(ho-h))
    let dt = dy+u*(abs(ho)+h+dy)+eta
    let gamma8 = 8*u/(1-8*u)
    var errors = [Double](), minima = [Double](), maxima = [Double]()
    for row in 0..<3 {
      let a = m[row*3], b = m[row*3+1], c = m[row*3+2]
      let values = [a*0+b*ho+c,a*w+b*ho+c,a*0+b*(ho-h)+c,a*w+b*(ho-h)+c]
      let terms = abs(a)*(w+dx)+abs(b)*(topY+dt)+abs(c)
      let flushA = abs(a) < eta ? abs(a)*(w+dx):0
      let flushB = abs(b) < eta ? abs(b)*(topY+dt):0
      let flushC = abs(c) < eta ? abs(c):0
      let coefficientFlush = flushA + flushB + flushC
      let error = (abs(a)*dx+abs(b)*dt+coefficientFlush+gamma8*terms+8*eta)*1.00000001
      guard values.allSatisfy(\.isFinite), terms.isFinite, terms < Double(Float.greatestFiniteMagnitude)/32,
        error.isFinite else { throw DevelopmentV3Error.invalidGraph }
      errors.append(error); minima.append(values.min()!); maxima.append(values.max()!)
    }
    let denominator = minima[2]-errors[2]
    let maximumDivisionDenominator: Double = 0x1p126
    guard denominator >= 1e-4, maxima[2]+errors[2] < maximumDivisionDenominator else { throw DevelopmentV3Error.invalidGraph }
    var quotientErrors = [Double](), quotientBounds = [Double]()
    for row in 0..<2 {
      let n = max(abs(minima[row]),abs(maxima[row]))
      // Perturbation of n/z around the exact uploaded-coefficient rational map, then division
      // roundoff. The lower denominator bound applies to every point, not only pixel centers.
      let bound = (n+errors[row])/denominator
      let error = (errors[row]+n*errors[2]/minima[2])/denominator+16*u*bound+eta
      guard bound.isFinite, bound < Double(Float.greatestFiniteMagnitude)/32, error.isFinite else { throw DevelopmentV3Error.invalidGraph }
      quotientBounds.append(bound); quotientErrors.append(error)
    }
    let yError = quotientErrors[1]+u*(abs(hs)+quotientBounds[1]+quotientErrors[1])+eta
    let e = max(quotientErrors[0],yError)*1.00000001
    let padding = 2+ceil(e) // one bilinear source pixel, ceil(E), one extra pixel reserve
    guard e.isFinite, padding.isFinite else { throw DevelopmentV3Error.invalidGraph }
    self.sourceExtent = sourceExtent; self.outputExtent = outputExtent; uploadedInverse = m
    uploadedSourceHeight = hs; uploadedOutputHeight = ho; sourceCoordinateError = e; halo = padding
  }

  func sourceRect(for requestedOutputRect: CGRect) -> CGRect {
    // Invalid nonempty geometry cannot be hidden as a successful transparent image. Init has
    // proved all finite output subrectangles safe; NaN rectangles violate the CI callback API.
    precondition(!requestedOutputRect.origin.x.isNaN && !requestedOutputRect.origin.y.isNaN &&
      !requestedOutputRect.width.isNaN && !requestedOutputRect.height.isNaN,"Invalid CI ROI request")
    let r = requestedOutputRect.intersection(outputExtent)
    if r.isNull || r.isEmpty { return .null }
    precondition(r.minX.isFinite && r.minY.isFinite && r.maxX.isFinite && r.maxY.isFinite)
    let m = uploadedInverse
    let corners = [(r.minX,r.minY),(r.maxX,r.minY),(r.minX,r.maxY),(r.maxX,r.maxY)]
    let points = corners.map { x,y -> CGPoint in
      let t = uploadedOutputHeight-y, z = m[6]*x+m[7]*t+m[8]
      return .init(x:(m[0]*x+m[1]*t+m[2])/z,
        y:uploadedSourceHeight-(m[3]*x+m[4]*t+m[5])/z)
    }
    // A positive affine homogeneous denominator makes each rational coordinate a positive
    // weighted combination of its corner values. Hence four edge corners bound the whole tile.
    let x0 = floor(points.map(\.x).min()!)-halo, x1 = ceil(points.map(\.x).max()!)+halo
    let y0 = floor(points.map(\.y).min()!)-halo, y1 = ceil(points.map(\.y).max()!)+halo
    precondition([x0,x1,y0,y1].allSatisfy(\.isFinite))
    // Keep the original clamped sampler and mandatory intermediate clip in the shader. This
    // intersection only bounds real source storage; it never clamps a mapped sample into a hit.
    return CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0).intersection(sourceExtent)
  }
}
