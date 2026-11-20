// Version-1.1 controlled-roll horizon crop Auto; native qualification is tracked separately.
import Foundation
import CoreImage
import ImageIO
import Vision
import RAWMasterCore

enum DevelopmentCropAutoV1 {
  static let version="crop-horizon-v1.1-controlled-roll/VNrev1/1024-768/conf.8/period180-.75deg/verify+3-3-.5deg/alpha.995/max15deg"
  static var available: Bool { VNDetectHorizonRequest.supportedRevisions.contains(1) }
  struct Observation { let degrees,confidence:Double }
  enum Rejection: Error { case noResult(DevelopmentCropAutoNoResultV1) }

  /// image is neutral, EXIF-oriented owned source BEFORE ANY geometry. Not a screen/previous rounded frame.
  static func resolve(image:CIImage,request:DevelopmentAnalysisRequest,source:DevelopmentLocalEditSourceBinding,
                      input:DevelopmentCropAutoInputV1,context:CIContext,
                      checkCancellation:()throws->Void) throws -> DevelopmentResolvedGeometryV1 {
    let binding=DevelopmentAnalysisBinding(sourceContentID:source.sourceContentID,sourceGeneration:request.preview.sourceGeneration,
      expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:request.stage)
    func result(_ resolution:DevelopmentGeometryResolutionV1)->DevelopmentResolvedGeometryV1 {
      .init(binding:binding,source:source,presentedRecipeFingerprint:request.presentedRecipeFingerprint,input:input,resolution:resolution)
    }
    try checkCancellation();try source.validate();try request.validate()
    guard request.stage == .orientedSourceBeforeGeometry,request.roi == NormalizedCrop(),
      let baseline=request.preview.recipe.adjustmentsV3?.geometry,
      input.baselineGeometryFingerprint == (try EditingFingerprint.of(baseline)) else { throw DevelopmentPreviewError.invalidRequest }
    guard image.extent.origin == .zero, image.extent.width == Double(source.orientedWidth), image.extent.height == Double(source.orientedHeight) else { throw DevelopmentPreviewError.invalidRequest }
    guard available else { return result(.noResult(.unsupportedDetector)) }
    guard DevelopmentCropGeometryAutoV1.supports(baseline) else { return result(.noResult(.unsupportedGeometry)) }
    guard min(source.orientedWidth,source.orientedHeight) >= 256 else { return result(.noResult(.insufficientResolution)) }
    // Keep both pre-D4 and late-D4. Remove only the angle/crop for detection; nonzero perspective was rejected.
    var detection=baseline;detection.straightenDegrees=0;detection.crop = .init()
    do {
      let oriented=try apply(image,geometry:detection,sourceSize:source.sourceSize)
      let first=try observe(oriented,maxEdge:1024,late:baseline.lateOrientation.orientation,context:context,check:checkCancellation)
      // Distinct scales even for a naturally small source: never count identical capped rasters as two-scale agreement.
      let secondEdge=min(768,max(1,Int(floor(min(1024,max(oriented.extent.width,oriented.extent.height))*0.75))))
      let second=try observe(oriented,maxEdge:secondEdge,late:baseline.lateOrientation.orientation,context:context,check:checkCancellation)
      guard abs(DevelopmentCropGeometryAutoV1.horizonDifference(first.degrees,second.degrees)) <= 0.75 else { return result(.noResult(.inconsistentScales)) }
      guard abs(first.degrees) <= 15,abs(first.degrees-baseline.straightenDegrees) <= 15 else { return result(.noResult(.excessiveRotation)) }
      guard abs(first.degrees-baseline.straightenDegrees) > 0.05 else { return result(.noResult(.unchanged)) }
      let candidate=try DevelopmentCropGeometryAutoV1.candidate(baseline:baseline,sourceSize:source.sourceSize,absoluteDegrees:first.degrees,aspectRatio:input.aspectRatio)
      var verifyGeometry=candidate;verifyGeometry.crop = .init()
      let corrected=try apply(image,geometry:verifyGeometry,sourceSize:source.sourceSize)
      let verified=try verifyControlledRoll(observe:{ knownRoll in
        let roll=try controlledRollTransform(width:corrected.extent.width,height:corrected.extent.height,knownRollDegrees:knownRoll)
        let rolled=corrected.transformed(by:roll.transform).cropped(to:roll.rect)
        return try observe(rolled,maxEdge:1024,late:.identity,context:context,check:checkCancellation)
      },checkCancellation:checkCancellation)
      try checkCancellation()
      let evidence=DevelopmentCropAutoEvidenceV1(firstDegrees:first.degrees,secondDegrees:second.degrees,
        firstConfidence:first.confidence,secondConfidence:second.confidence,verificationPair:verified)
      let resolved=result(.candidate(candidate,evidence))
      _=try resolved.validatedCandidate(baseline:baseline,expectedSource:source,expectedInput:input)
      return resolved
    } catch Rejection.noResult(let reason) { try checkCancellation();return result(.noResult(reason)) }
  }
  /// Fixed v1.1 sequence. Missing/low-confidence observations never mean a horizontal horizon.
  /// Closure seam permits CPU-only contract/cancellation tests; production closure performs real VNrev1.
  static func verifyControlledRoll(observe:(Double)throws->Observation?,checkCancellation:()throws->Void) throws -> DevelopmentCropAutoVerificationPairV1 {
    func actual(_ knownRoll:Double)throws->DevelopmentCropAutoVerificationObservationV1 {
      try checkCancellation()
      let observed=try observe(knownRoll)
      try checkCancellation()
      guard let observation=observed else { throw Rejection.noResult(.noHorizon) }
      guard observation.confidence.isFinite,(0.8...1).contains(observation.confidence) else { throw Rejection.noResult(.lowConfidence) }
      guard observation.degrees.isFinite else { throw Rejection.noResult(.failedVerification) }
      return .init(knownRollDegrees:knownRoll,correctionDegrees:observation.degrees,confidence:observation.confidence)
    }
    let positive=try actual(3),negative=try actual(-3)
    let pair=DevelopmentCropAutoVerificationPairV1(positiveRoll:positive,negativeRoll:negative)
    do { try pair.validate() } catch { throw Rejection.noResult(.failedVerification) }
    try checkCancellation();return pair
  }
  /// Same positive displayed-space straighten/center/inscribed trim as Core, on a CONTINUOUS corrected extent.
  /// This scratch-only transform does not round, alter candidate geometry or touch final export mapping.
  static func controlledRollTransform(width:Double,height:Double,knownRollDegrees:Double)throws->(transform:CGAffineTransform,rect:CGRect) {
    guard [width,height,knownRollDegrees].allSatisfy(\.isFinite),width > 0,height > 0,
      knownRollDegrees == 3 || knownRollDegrees == -3 else { throw DevelopmentPreviewError.invalidRequest }
    let a=knownRollDegrees * .pi/180,c=cos(a),s=sin(a),S=sin(abs(a)),C=cos(abs(a))
    let long=max(width,height),short=min(width,height)
    let size:(Double,Double)
    // Identical inscribed-size branches to DevelopmentGeometryV3; retain fractional corrected extent.
    if short <= 2*S*C*long || abs(C-S) < 1e-10 {
      let x=short/2
      size=width >= height ? (x/max(S,1e-10),x/C):(x/C,x/max(S,1e-10))
    } else {
      let cos2=C*C-S*S;size=((width*C-height*S)/cos2,(height*C-width*S)/cos2)
    }
    let w=size.0,h=size.1
    return (.init(a:c,b:s,c:-s,d:c,tx:w/2-c*width/2+s*height/2,ty:h/2-s*width/2-c*height/2),.init(x:0,y:0,width:w,height:h))
  }
  private static func observe(_ image:CIImage,maxEdge:Int,late:DevelopmentD4OrientationV3,context:CIContext,
                              check:()throws->Void) throws -> Observation {
    try autoreleasepool {
      try check()
      let extent=image.extent
      guard !extent.isInfinite,!extent.isEmpty,[extent.width,extent.height].allSatisfy(\.isFinite) else { throw DevelopmentPreviewError.invalidRequest }
      let scale=min(1,Double(maxEdge)/max(extent.width,extent.height))
      let w=max(1,Int(floor(extent.width*scale))),h=max(1,Int(floor(extent.height*scale)))
      let shifted=image.transformed(by:.init(translationX:-extent.minX,y:-extent.minY))
      let proxy=shifted.transformed(by:.init(scaleX:Double(w)/extent.width,y:Double(h)/extent.height))
      let color=CGColorSpace(name:CGColorSpace.sRGB)!
      // Core Image owns the CGImage orientation conversion. Do not reinterpret raw CI bitmap
      // row order as a CGImage: that would introduce an unverified vertical flip before Vision.
      guard let cg=context.createCGImage(proxy,from:.init(x:0,y:0,width:w,height:h),format:.RGBA8,colorSpace:color) else { throw DevelopmentPreviewError.invalidRequest }
      try check()
      var bytes=[UInt8](repeating:0,count:w*h*4)
      let bitmapInfo=CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
      try bytes.withUnsafeMutableBytes { data in
        guard let cpu=CGContext(data:data.baseAddress!,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,space:color,bitmapInfo:bitmapInfo) else { throw DevelopmentPreviewError.invalidRequest }
        cpu.draw(cg,in:.init(x:0,y:0,width:w,height:h))
      }
      try check()
      var opaque=0,minL=255,maxL=0
      for i in stride(from:0,to:bytes.count,by:4) {
        if bytes[i+3] >= 254 { opaque += 1;let l=(Int(bytes[i])+Int(bytes[i+1])+Int(bytes[i+2]))/3;minL=min(minL,l);maxL=max(maxL,l) }
      }
      guard Double(opaque)/Double(w*h) >= 0.995 else { throw Rejection.noResult(.opaqueContentRequired) }
      guard maxL-minL >= 8 else { throw Rejection.noResult(.noHorizon) }
      let vision=VNDetectHorizonRequest();vision.revision=1
      // No Task, native pool or async bridge. Cancellation revokes delivery immediately; this perform must RETURN before joined.
      try check();try VNImageRequestHandler(cgImage:cg,orientation:.up,options:[:]).perform([vision]);try check()
      guard let observations=vision.results,observations.count == 1 else { throw Rejection.noResult(.noHorizon) }
      let value=observations[0],confidence=Double(value.confidence),t=value.transform
      guard confidence.isFinite,(0.8...1).contains(confidence) else { throw Rejection.noResult(.lowConfidence) }
      // transform translation is irrelevant to roll; reject nonrotation/scaled/sheared linear parts in Core.
      guard [Double(t.a),Double(t.b),Double(t.c),Double(t.d),Double(t.tx),Double(t.ty),Double(value.angle)].allSatisfy(\.isFinite) else { throw Rejection.noResult(.failedVerification) }
      let angle: Double
      do { angle=try DevelopmentCropGeometryAutoV1.absoluteStraighten(bottomLeftLinear:[t.a,t.b,t.c,t.d],late:late) }
      catch { throw Rejection.noResult(.failedVerification) }
      return .init(degrees:angle,confidence:confidence)
    }
  }
  /// Affine only. Derive CI bottom-left mapping from the continuous Core cropPlane, never integer outputSize.
  private static func apply(_ image:CIImage,geometry:DevelopmentGeometryV3,sourceSize:DevelopmentPixelSize)throws->CIImage {
    let map=try geometry.mapping(sourceSize:sourceSize),p=map.cropPlane,m=p.forwardMatrix
    guard m.count == 9,m[6] == 0,m[7] == 0,m[8] == 1 else { throw DevelopmentPreviewError.invalidRequest }
    let h=Double(sourceSize.height),H=p.rect.height
    // F_out * M_topLeft * F_in, including continuous crop-plane trim translation.
    let ci=CGAffineTransform(a:m[0],b:-m[3],c:-m[1],d:m[4],tx:m[1]*h+m[2],ty:H-m[4]*h-m[5])
    return image.transformed(by:ci).cropped(to:.init(x:0,y:0,width:p.rect.width,height:p.rect.height))
  }
}
