import Foundation
import CoreImage
import Darwin
import RAWMasterCore

/// Explicit natural-curve analysis contract; does not change the legacy Picker or Auto.
public enum DevelopmentNaturalCurvePickerV1 {
  public static let samplingVersion = "natural-precurve-v1"
  public static func isNatural(_ request: DevelopmentAnalysisRequest) -> Bool {
    guard case .curvePicker = request.operation else { return false }
    return request.preview.recipe.adjustmentsV3?.curves.algorithm == .naturalCubicGamma512LumaV1
  }
  public static func supports(_ p: DevelopmentAdjustmentsV3, sourceIsRAW: Bool) -> Bool {
    (try? validateAdmission(p,sourceIsRAW:sourceIsRAW)) != nil
  }
  static func validateAdmission(_ p: DevelopmentAdjustmentsV3, sourceIsRAW: Bool) throws {
    try p.validate(); try p.noiseReduction.validate(for:sourceIsRAW ? .raw:.image)
    guard p.curves.algorithm == .naturalCubicGamma512LumaV1,
      !DevelopmentColorEngineV3.levelsActive(p.levels),
      !(p.definition.enabled && p.definition.amount != 0),
      !(p.selectiveColor.enabled && (p.selectiveColor.colors.contains { $0.hue != 0 || $0.saturation != 0 || $0.luminance != 0 || ($0.variance ?? 0) != 0 } || p.selectiveColor.pointColors?.contains(where:\.isActive) == true)),
      !(!sourceIsRAW && p.noiseReduction.enabled && p.noiseReduction.nonRawAmount != 0),
      !(p.sharpen.enabled && p.sharpen.intensity != 0),
      !(p.vignette.enabled && p.vignette.strength != 0),
      !(p.filter.enabled && p.filter.selection != .original && p.filter.intensity != 0),
      !p.advancedDetail.hasEffects,
      !p.localEdits.operations.contains(where: { operation in
        (operation.tool == .retouch ? p.localEdits.retouchEnabled:p.localEdits.redEyeEnabled)
          && operation.stroke.strength != 0 && operation.stroke.points.contains { $0.pressure > 0 }
      }) else { throw DevelopmentV3Error.unsupportedAnalysis }
    // Only registered stages may be neutralized. A future non-neutral field fails closed
    // until its position and identity predicate have been reviewed for this endpoint.
    var rest = p
    rest.legacyBasis=nil;rest.light = .init();rest.color = .init();rest.blackAndWhite = .init()
    rest.whiteBalance = .init();rest.curves = .init();rest.geometry = .init()
    rest.levels = .init();rest.definition = .init();rest.selectiveColor = .init()
    rest.noiseReduction = .init();rest.sharpen = .init();rest.vignette = .init()
    rest.filter = .init();rest.localEdits = .init();rest.advancedDetail = .init()
    guard rest == DevelopmentAdjustmentsV3() else { throw DevelopmentV3Error.unsupportedAnalysis }
  }
  /// Both service and editor reject wrong-purpose or cross-model returned payloads.
  public static func acceptsCommand(_ command:DevelopmentResolvedAdjustmentCommand, request:DevelopmentAnalysisRequest) -> Bool {
    guard isNatural(request),case .curvePicker(let channel,_,_) = request.operation,
      command.purpose == .curvesPicker,command.parameters.count == 1,
      case .curves(let returned)=command.parameters[0],returned.enabled,
      returned.algorithm == .naturalCubicGamma512LumaV1,
      var expected=request.preview.recipe.adjustmentsV3?.curves else { return false }
    expected.enabled=true
    switch channel { case .rgb:expected.rgb=returned.rgb;case .red:expected.red=returned.red;case .green:expected.green=returned.green;case .blue:expected.blue=returned.blue }
    return returned == expected && (try? DevelopmentNaturalCubicCurvesV1.tables(returned)) != nil
  }
  /// A checked joined 1x1 linear premultiplied F32 read. Never sample display RGB8.
  static func sample(_ image: CIImage, position: DevelopmentSourcePoint, context: CIContext,
                     checkCancellation: (() throws -> Void)? = nil) throws -> SIMD4<Float> {
    try position.validate(); try Task.checkCancellation(); try checkCancellation?()
    let e=image.extent
    guard !e.isEmpty,!e.isInfinite,e.minX.isFinite,e.minY.isFinite,e.width.isFinite,e.height.isFinite,
      e.width == floor(e.width),e.height == floor(e.height) else { throw DevelopmentV3Error.invalidGraph }
    let x=e.minX+min(e.width-1,floor(position.x*e.width))
    let y=e.minY+min(e.height-1,floor((1-position.y)*e.height))
    var pixel=SIMD4<Float>(repeating:Float.nan)
    try withUnsafeMutableBytes(of:&pixel) { bytes in
      let destination=CIRenderDestination(bitmapData:bytes.baseAddress!,width:1,height:1,bytesPerRow:16,format:.RGBAf)
      destination.colorSpace=DevelopmentColorEngineV3.linearSRGB;destination.alphaMode = .premultiplied
      destination.isClamped=false;destination.isDithered=false;destination.isFlipped=false
      let task=try context.startTask(toRender:image,from:.init(x:x,y:y,width:1,height:1),to:destination,at:.zero)
      do { _ = try task.waitUntilCompleted() }
      catch { let original=error; _ = try? task.waitUntilCompleted(); throw original }
    }
    try Task.checkCancellation(); try checkCancellation?()
    guard [pixel.x,pixel.y,pixel.z,pixel.w].allSatisfy(\.isFinite) else { throw DevelopmentError.invalidEncoding }
    return pixel
  }
  static func command(curves original: DevelopmentCurvesV3, pixel: SIMD4<Float>, channel: DevelopmentCurveChannelV3ID,
                      point: DevelopmentCurvePickerPointV3, binding: DevelopmentAnalysisBinding) throws -> DevelopmentResolvedAdjustmentCommand {
    try original.validate()
    guard original.algorithm == .naturalCubicGamma512LumaV1 else { throw DevelopmentV3Error.unsupportedAnalysis }
    guard [pixel.x,pixel.y,pixel.z,pixel.w].allSatisfy(\.isFinite),pixel.w >= 0,pixel.w <= 1 else { throw DevelopmentError.invalidEncoding }
    guard pixel.w > 0 else { throw DevelopmentAnalysisError.noVisibleSamples }
    let straight=SIMD3<Float>(try DevelopmentNaturalCubicCurvesV1.finite(pixel.x/pixel.w),
      try DevelopmentNaturalCubicCurvesV1.finite(pixel.y/pixel.w),try DevelopmentNaturalCubicCurvesV1.finite(pixel.z/pixel.w))
    var curves=original
    let linear:Float
    switch channel {
    case .red: linear=straight.x
    case .green: linear=straight.y
    case .blue: linear=straight.z
    case .rgb:
      // A successful pick enables the group, including its stored RGB channel rows.
      let tables=try DevelopmentNaturalCubicCurvesV1.tables(curves)
      linear=try DevelopmentNaturalCubicCurvesV1.mappedRGBAndLuma(straight,tables:tables).luma
    }
    guard linear.isFinite,(Float(0)...Float(1)).contains(linear) else { throw DevelopmentV3Error.unrepresentableParameters }
    let u=try DevelopmentNaturalCubicCurvesV1.finite(Darwin.powf(linear,Float(1.0/2.2)))
    var target:DevelopmentCurveChannelV3
    switch channel { case .rgb:target=curves.rgb;case .red:target=curves.red;case .green:target=curves.green;case .blue:target=curves.blue }
    let black=Float(target.inputBlack),white=Float(target.inputWhite)
    let span=try DevelopmentNaturalCubicCurvesV1.finite(white-black)
    guard black.isFinite,white.isFinite,span>0 else { throw DevelopmentV3Error.unrepresentableParameters }
    switch point {
    case .black:
      guard u<white else { throw DevelopmentV3Error.unrepresentableParameters };target.inputBlack=Double(u)
    case .white:
      guard u>black else { throw DevelopmentV3Error.unrepresentableParameters };target.inputWhite=Double(u)
    case .midtone,.addPoint:
      let x=try DevelopmentNaturalCubicCurvesV1.finite((u-black)/span)
      guard x>Float(1e-4),x<Float(1-1e-4) else { throw DevelopmentV3Error.unrepresentableParameters }
      let y:Float=point == .midtone ? 0.5:try DevelopmentNaturalCubicCurvesV1.evaluate(DevelopmentNaturalCubicCurvesV1.model(target.curve),x)
      guard y.isFinite,(Float(0)...Float(1)).contains(y) else { throw DevelopmentV3Error.unrepresentableParameters }
      if let index=target.curve.points.indices.dropFirst().dropLast().first(where:{ abs(target.curve.points[$0].x-Double(x))<1e-4 }) {
        target.curve.points[index] = .init(x:Double(x),y:Double(y))
      } else {
        guard target.curve.points.count<16 else { throw DevelopmentV3Error.unrepresentableParameters }
        target.curve.points.append(.init(x:Double(x),y:Double(y)));target.curve.points.sort { $0.x<$1.x }
      }
    }
    try target.validate();curves.enabled=true
    switch channel { case .rgb:curves.rgb=target;case .red:curves.red=target;case .green:curves.green=target;case .blue:curves.blue=target }
    _ = try DevelopmentNaturalCubicCurvesV1.tables(curves)
    return .init(binding:binding,purpose:.curvesPicker,parameters:[.curves(curves)])
  }
}
