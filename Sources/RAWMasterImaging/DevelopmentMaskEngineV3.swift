import Foundation
import CoreImage
import Metal
import RAWMasterCore
import RAWMasterImage

/// Source-space, ordered local tonal and Glow layers. Subject inference is captured into the recipe;
/// replay is deterministic. Glow style/range/spread/warmth/direction/softness are globally shared.
enum DevelopmentMaskEngineV3 {
  static let operatorVersion="mask-v14-local-dehaze/linear-radial-range-subject/ordered-f32/source-normalized/local-glow-fused-v1/local-point-color-v1/local-light-extended-v1/local-wb-composite-v1/local-hue-colorize-v1/local-log-bands-v1/local-grain-v1/local-curves-v1/local-grading-v1/local-detail-v1/local-defringe-protection-v1/point-library-isolated-v1"
  private struct Kernels { let layer,glowLayer,pointColor,pointColorOnly,composite,grain,sourceGrain,moire,dehaze,scopeCoverage:CIKernel }
  private static let kernels:Result<Kernels,Error>=Result {
    guard DevelopmentKernelCapability.supported else{throw DevelopmentError.unsupportedEngine}
    let source = try RAWMasterImageKernel.source(.mask)
    let all=try CIKernel.kernels(withMetalString:source)
    // Keep the point-cloud kernel isolated from differently parameterized layer kernels.
    let pointAll=try CIKernel.kernels(withMetalString:source)
    func get(_ name:String,kernels:[CIKernel])->CIKernel?{kernels.first(where:{$0.name==name})}
    guard let layer=get("rmMaskLayerV7",kernels:all),let glowLayer=get("rmMaskGlowLayerV7",kernels:all),
      let pointColor=get("rmMaskPointColorV7",kernels:pointAll),let pointColorOnly=get("rmMaskPointColorOnly",kernels:pointAll),let composite=get("rmMaskComposite",kernels:all),
      let grain=get("rmMaskGrain",kernels:all),let sourceGrain=get("rmSourceMaskGrain",kernels:all),let moire=get("rmMaskMoire",kernels:all),let dehaze=get("rmMaskDehaze",kernels:all),
      let scopeCoverage=get("rmMaskScopeCoverage",kernels:all) else{throw DevelopmentError.unsupportedEngine}
    return .init(layer:layer,glowLayer:glowLayer,pointColor:pointColor,pointColorOnly:pointColorOnly,composite:composite,grain:grain,sourceGrain:sourceGrain,moire:moire,dehaze:dehaze,scopeCoverage:scopeCoverage)
  }
  /// Captures coverage before the selected layer edits its pixels. Later layers may change
  /// the displayed colors without changing which pixels a luminance range originally selected.
  final class ScopeSelection {
    let layer: DevelopmentMaskLayerV3
    private(set) var coverage: CIImage?
    init(_ layer: DevelopmentMaskLayerV3) { self.layer = layer }
    func capture(_ input: CIImage) throws {
      let (subject, args) = try maskInputs(layer, image: input)
      guard let result = try kernels.get().scopeCoverage.apply(extent: input.extent,
        roiCallback:maskROI(layer, subject:subject, index:1), arguments: args) else { throw DevelopmentV3Error.invalidGraph }
      coverage = result
    }
  }
  private static func maskInputs(_ layer: DevelopmentMaskLayerV3, image: CIImage, opacity: Double? = nil) throws -> (CIImage, [Any]) {
    let subject: CIImage
    if layer.kind == .subject {
      guard let data = layer.subjectPNG, let decoded = CIImage(data: data, options: layer.semanticSnapshot == nil ? [:] : [.colorSpace: NSNull()]), !decoded.extent.isEmpty else { throw DevelopmentError.unreadable }
      subject = decoded.transformed(by: .init(translationX: -decoded.extent.minX, y: -decoded.extent.minY))
        .transformed(by: .init(scaleX: image.extent.width / decoded.extent.width, y: image.extent.height / decoded.extent.height))
    } else { subject = CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 1, height: 1)) }
    let kind: Double = switch layer.kind { case .linear: 0; case .radial: 1; case .range: 2; case .subject: 3 }
    return (subject, [image, subject, CIVector(x: kind, y: layer.inverted ? 1 : 0, z: opacity ?? layer.opacity, w: layer.feather),
      CIVector(x: layer.start.x, y: layer.start.y, z: layer.end.x, w: layer.end.y),
      CIVector(x: layer.center.x, y: layer.center.y, z: layer.radiusX, w: layer.radiusY),
      CIVector(x: layer.rangeLower, y: layer.rangeUpper, z: image.extent.width, w: image.extent.height)])
  }
  /// Frozen Gray8 is already transformed to source coordinates. Each pointwise kernel samples
  /// only its output tile and one original Gray8 texel on either side for interpolation.
  /// Requesting the entire upscaled matte for every finite-reduction tile forces a native F32
  /// intermediate (about 960 MB on a 61 MP capture), including for a one-pixel reduction.
  static func maskROI(_ layer: DevelopmentMaskLayerV3, subject: CIImage, index: Int32) -> CIKernelROICallback {
    let extent = subject.extent
    guard let snapshot = layer.semanticSnapshot else { return { sampler, rect in sampler == index ? extent : rect } }
    let dx = max(1, ceil(extent.width / CGFloat(snapshot.width)))
    let dy = max(1, ceil(extent.height / CGFloat(snapshot.height)))
    return { sampler, rect in
      sampler == index ? rect.insetBy(dx: -dx, dy: -dy).intersection(extent) : rect
    }
  }
  static func prewarm(){_ = try? kernels.get()}
  static func active(_ layers:[DevelopmentMaskLayerV3])->Bool {
    layers.contains{$0.enabled && $0.opacity>0 && !$0.adjustments.isNeutral}
  }
  static func usesDefringe(_ layers:[DevelopmentMaskLayerV3])->Bool {
    layers.contains{$0.enabled && $0.opacity>0 && ($0.adjustments.defringe ?? 0) != 0}
  }
  private static func pointParameters(_ sample:DevelopmentPointColorSampleV3)->(CIVector,CIVector) {
    let color=sample.sampledColor
    let encoded=SIMD3<Double>(DevelopmentColorEngineV2.encode(color.red),DevelopmentColorEngineV2.encode(color.green),DevelopmentColorEngineV2.encode(color.blue))
    let high=max(encoded.x,max(encoded.y,encoded.z)),low=min(encoded.x,min(encoded.y,encoded.z))
    let saturation=high>1e-8 ? (high-low)/high:0
    return (CIVector(x:DevelopmentGlobalEngineV3.hue(encoded),y:sample.hue/360,z:sample.saturation/100,w:sample.luminance/70),
      CIVector(x:sample.range,y:(sample.variance ?? 0)/100,z:saturation,w:high))
  }
  struct CanonicalValidation {
    enum Transport {
      case pairedTiles, metalBands, localNoiseBands, pointwiseRegion, pointwiseCompositeRegion, spatialTileRegion, groupedFull

      var checksPointwiseRegion: Bool { self == .pointwiseRegion || self == .pointwiseCompositeRegion }
    }
    enum SpatialTileScope {
      case disabled, textureAndClarity, includingGrain

      static let current: Self = {
        let environment = ProcessInfo.processInfo.environment
        guard DevelopmentCanonicalFiniteGPU.enabled, environment["RAWMASTER_CANONICAL_SPATIAL_MASK_TILES"] != "0" else { return .disabled }
        return environment["RAWMASTER_QA_CANONICAL_GRAIN_MASK_TILES"] == "0" ? .textureAndClarity : .includingGrain
      }()
    }

    private static let pointwiseRegionEnabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_POINT_MASK_REGION"] == "1"
    private static let pointwiseCompositeRegionEnabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_POINT_COMPOSITE_REGION"] == "1"
    private static let localNoiseBandsEnabled = ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_LOCAL_NOISE_BANDS"] == "1"
    fileprivate static let textureRegionBandsEnabled = DevelopmentCheckedMaximumV3.groupedScalarsEnabled &&
      ProcessInfo.processInfo.environment["RAWMASTER_QA_CANONICAL_TEXTURE_REGION_BANDS"] == "1"
    private static let spatialTransport: Transport? = {
      let environment = ProcessInfo.processInfo.environment
      if DevelopmentCanonicalFiniteGPU.enabled && environment["RAWMASTER_QA_CANONICAL_LOCAL_MASK_BANDS"] == "1" {
        return .metalBands
      }
      return environment["RAWMASTER_QA_LOCAL_BAND_PAIR_CLEAR"] == "1" ? .pairedTiles : nil
    }()

    let transport: Transport
    let scalarBatching: DevelopmentCheckedMaximumV3.ScalarBatching
    let checkCancellation: () throws -> Void
    init(transport: Transport, scalarBatching: DevelopmentCheckedMaximumV3.ScalarBatching = .disabled,
         checkCancellation: @escaping () throws -> Void) {
      self.transport = transport
      self.scalarBatching = scalarBatching
      self.checkCancellation = checkCancellation
    }

    func requiresOpaqueGrainInput(_ p: DevelopmentAdjustmentsV3) -> Bool {
      transport == .spatialTileRegion && (p.masks.first?.adjustments.grain ?? 0) > 0
    }

    static func requestedTransport(for p: DevelopmentAdjustmentsV3?) -> Transport? {
      if DevelopmentCanonicalFiniteGPU.enabled, pointwiseRegionEnabled, let p, pointwiseLayer(p) != nil {
        return .pointwiseRegion
      }
      guard let p else { return nil }
      if DevelopmentCanonicalFiniteGPU.enabled, pointwiseCompositeRegionEnabled, pointwiseCompositeLayer(p) != nil {
        return .pointwiseCompositeRegion
      }
      if let spatialTransport, spatialLayer(p, transport: spatialTransport, spatialTiles: .current) != nil {
        return spatialTransport
      }
      if DevelopmentCanonicalFiniteGPU.enabled, localNoiseBandsEnabled,
         spatialLayer(p, transport: .localNoiseBands, spatialTiles: .current) != nil {
        return .localNoiseBands
      }
      if spatialLayer(p, transport: .spatialTileRegion, spatialTiles: .current) != nil { return .spatialTileRegion }
      if DevelopmentCheckedMaximumV3.allowsScalarGrouping,
         let layer = spatialLayer(p, transport: .groupedFull, spatialTiles: .current),
         (layer.adjustments.noiseReduction ?? 0) > 0 || DevelopmentCheckedMaximumV3.groupedScalarsEnabled {
        return .groupedFull
      }
      return nil
    }

    static func pointwiseLayer(_ p: DevelopmentAdjustmentsV3) -> DevelopmentMaskLayerV3? {
      guard let layer = singleHardRadialLayer(p) else { return nil }
      let a = layer.adjustments
      let singleAdjustment: [DevelopmentMaskAdjustmentsV3] = [
        .init(exposure:a.exposure), .init(highlights:a.highlights), .init(shadows:a.shadows), .init(saturation:a.saturation),
        .init(contrast:a.contrast), .init(whites:a.whites), .init(blacks:a.blacks), .init(hue:a.hue,fineAdjustment:a.fineAdjustment),
      ]
      return singleAdjustment.contains(a) ? layer : nil
    }

    private static func pointwiseCompositeLayer(_ p: DevelopmentAdjustmentsV3) -> DevelopmentMaskLayerV3? {
      guard let layer = singleHardRadialLayer(p) else { return nil }
      let a = layer.adjustments
      let singleAdjustment: [DevelopmentMaskAdjustmentsV3] = [
        .init(temperature:a.temperature), .init(tint:a.tint), .init(grading:a.grading),
      ]
      return singleAdjustment.contains(a) ? layer : nil
    }

    private static func singleHardRadialLayer(_ p: DevelopmentAdjustmentsV3) -> DevelopmentMaskLayerV3? {
      guard p.rawDecoder == .flashRaw031, p.masks.count == 1, let layer = p.masks.first,
            layer.enabled, layer.kind == .radial, !layer.inverted, layer.feather == 0, layer.opacity == 1,
            layer.subjectPNG == nil, layer.semanticSnapshot == nil, !layer.adjustments.isNeutral else { return nil }
      var permitted = p.neutralForSameSource
      permitted.masks = [layer]
      return permitted == p ? layer : nil
    }

    static func pointwiseSupport(_ layer: DevelopmentMaskLayerV3, extent: CGRect) -> CGRect? {
      guard extent.origin == .zero, extent == extent.integral, (1...9504).contains(extent.width),
            (1...6336).contains(extent.height), !extent.isInfinite,
            (0...1).contains(layer.center.x), (0...1).contains(layer.center.y),
            (0.001...2).contains(layer.radiusX), (0.001...2).contains(layer.radiusY) else { return nil }
      let x = CGFloat(Float(layer.center.x)), y = 1 - CGFloat(Float(layer.center.y))
      // The radial shader still uses a 1e-5 transition at zero feather. Use the
      // actual Float32 uniforms, expand that transition and leave room for sample
      // centers and Float32 coordinate arithmetic before rounding outward.
      let margin = CGFloat(32 * Float.ulpOfOne)
      let rx = (CGFloat(Float(layer.radiusX)) * 1.00002 + margin) * extent.width + 2
      let ry = (CGFloat(Float(layer.radiusY)) * 1.00002 + margin) * extent.height + 2
      let region = CGRect(x:x*extent.width-rx,y:y*extent.height-ry,width:2*rx,height:2*ry).integral.intersection(extent)
      return region.isEmpty || region == extent ? nil : region
    }

    static func qualifies(_ p: DevelopmentAdjustmentsV3, extent: CGRect, transport: Transport,
                          spatialTiles: SpatialTileScope = .current) -> Bool {
      if transport.checksPointwiseRegion {
        let selected = transport == .pointwiseRegion ? pointwiseLayer(p) : pointwiseCompositeLayer(p)
        guard let layer = selected else { return false }
        return pointwiseSupport(layer,extent:extent) != nil
      }
      guard extent.origin == .zero, extent == extent.integral, extent.width >= extent.height,
            extent.height > 0, extent.width <= 9504, extent.height <= 6336,
            let layer = spatialLayer(p, transport: transport, spatialTiles: spatialTiles) else { return false }
      return transport != .spatialTileRegion || spatialTileSupport(layer, extent: extent) != nil
    }

    static func spatialTileSupport(_ layer: DevelopmentMaskLayerV3, extent: CGRect, sourceGrainScale: Double? = nil) -> CGRect? {
      // A proxy grain scale selects a different kernel and can omit the neutral tonal tail.
      guard sourceGrainScale == nil, let support = pointwiseSupport(layer, extent: extent) else { return nil }
      // The final tonal layer and finite mask each sample the preceding image once.
      // Keep both footprints and use the same absolute reduction cells as the full scan.
      let padded = support.insetBy(dx: -2, dy: -2).intersection(extent)
      let side = DevelopmentCheckedMaximumV3.tileSide
      let x = floor(padded.minX / side) * side, y = floor(padded.minY / side) * side
      let region = CGRect(x: x, y: y, width: ceil(padded.maxX / side) * side - x,
                          height: ceil(padded.maxY / side) * side - y).intersection(extent)
      return region.isEmpty || region == extent ? nil : region
    }

    private static func spatialLayer(_ p: DevelopmentAdjustmentsV3, transport: Transport,
                                     spatialTiles: SpatialTileScope) -> DevelopmentMaskLayerV3? {
      guard transport != .spatialTileRegion || spatialTiles != .disabled,
            p.rawDecoder == .flashRaw031, p.masks.count == 1, let layer = p.masks.first,
            layer.enabled, layer.kind == .radial, layer.opacity == 1, layer.feather == 0, !layer.inverted,
            layer.subjectPNG == nil, layer.semanticSnapshot == nil else { return nil }
      let a = layer.adjustments
      let texture = (a.texture ?? 0) > 0 && a == .init(texture: a.texture)
      let clarity = (a.clarity ?? 0) > 0 && a == .init(clarity: a.clarity)
      let grain = (a.grain ?? 0) > 0 && a == .init(grain: a.grain, grainSize: 0.25, grainRoughness: 0.5)
      let noise = (a.noiseReduction ?? 0) > 0 && a == .init(noiseReduction: a.noiseReduction)
      let sharpness = (a.sharpness ?? 0) > 0 && a == .init(sharpness: a.sharpness)
      guard transport != .localNoiseBands || noise else { return nil }
      // The canonical grain lattice produces bounded noise and composites it only at nonzero coverage.
      // Sharpen and denoise keep their existing scan because they use the shared adjusted-image composite.
      let grainTiles = transport == .spatialTileRegion && spatialTiles == .includingGrain && grain && (a.grain ?? 0) <= 1
      let fullBands = (transport == .metalBands && (grain || noise || sharpness)) || transport == .localNoiseBands
      let curves = a.curves?.enabled == true && a == .init(curves:a.curves)
      let groupedFull = transport == .groupedFull && (grain || noise || curves)
      guard texture || clarity || grainTiles || fullBands || groupedFull else { return nil }
      var allowed = p.neutralForSameSource
      allowed.masks = [layer]
      return p == allowed ? layer : nil
    }
  }

  static func apply(_ layers:[DevelopmentMaskLayerV3],to input:CIImage,context:CIContext,
                    glow sharedGlow:DevelopmentGlowV3?=nil,optics:DevelopmentOpticsV3?=nil,
                    checkCancellation:(()throws->Void)?=nil,deferValidation:Bool=false,canonicalValidation:CanonicalValidation?=nil,scopeSelection:ScopeSelection?=nil,sourceGrainScale:Double?=nil,legacyCoverage:DevelopmentLegacyMaskOutput.Coverage?=nil,
                    previewHalfFIT:PreviewCanonicalHalfFIT?=nil,nativeSharpenMean:PreviewNativeSharpenMean?=nil)throws->CIImage {
    try DevelopmentMaskLayerV3.validateLayers(layers)
    guard active(layers) else { try scopeSelection?.capture(input); return input }
    try sharedGlow?.validate()
    let hasGlow=layers.contains{$0.enabled && $0.opacity>0 && ($0.adjustments.glowAmount ?? 0)>0}
    let localDefringe=usesDefringe(layers)
    let telemetry=ImagePerformanceTelemetry.shared.begin(operation:"DevelopmentMaskEngineV3.apply",
      stage:hasGlow ? "local-glow":localDefringe ? "local-defringe":"local-tone",boundary:deferValidation ? .graphBuild : .apiReturn)
    let pixels=Int(input.extent.width*input.extent.height)
    var telemetryOutcome=ImagePerformanceOutcome.failed
    defer{ImagePerformanceTelemetry.shared.end(telemetry,outcome:telemetryOutcome,pixelCount:pixels)}
    let kernels=try self.kernels.get()
    var image=input
    var usedNativeSharpenMean = false
    if localDefringe {
      // Global correction is deferred only for this new path. Negative amounts restore the actual
      // pre-Defringe pixels, rather than undoing earlier local layers or adding another blur.
      let unprotected=image
      image=try DevelopmentDefringeEngineV3.apply(optics,to:image)
      for layer in layers where layer.enabled && layer.opacity>0 && (layer.adjustments.defringe ?? 0)<0 {
        try checkCancellation?()
        let (subject, geometry) = try maskInputs(layer, image: image, opacity: layer.opacity * min(1, -(layer.adjustments.defringe ?? 0)))
        var args = geometry
        args.insert(unprotected,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:args)else{throw DevelopmentError.unreadable}
        image=output
      }
    }
    for layer in layers {
      if layer.id == scopeSelection?.layer.id { try scopeSelection?.capture(image) }
      guard layer.enabled, layer.opacity>0, !layer.adjustments.isNeutral else { continue }
      try checkCancellation?()
      try legacyCoverage?.capture(layer, input: image)
      let a=layer.adjustments
      let (subject, geometry) = try maskInputs(layer, image: image)
      var args: [Any] = geometry + [
        CIVector(x:a.exposure,y:a.highlights,z:a.shadows,w:a.saturation),
        CIVector(x:a.contrast ?? 0,y:a.whites ?? 0,z:a.blacks ?? 0,w:0),
        CIVector(x:a.hue ?? 0,y:a.fineAdjustment == true ? 0.1:1,z:a.colorizeAmount ?? 1,w:0),
        CIVector(x:a.colorize?.red ?? 0,y:a.colorize?.green ?? 0,z:a.colorize?.blue ?? 0,w:a.colorize == nil ? 0:1)]
      let temperature=a.temperature ?? 0,tint=a.tint ?? 0
      if temperature != 0 || tint != 0 {
        // Local offsets are defined around the image-working 6500K reference, not camera As Shot metadata.
        let warmed=image.applyingFilter("CITemperatureAndTint",parameters:[
          "inputNeutral":CIVector(x:6500,y:0),
          "inputTargetNeutral":CIVector(x:6500+5000*temperature,y:150*tint)])
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(warmed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      let texture=a.texture ?? 0,clarity=a.clarity ?? 0
      if texture != 0 || clarity != 0 {
        let portrait=image.extent.height>image.extent.width
        let bandInput=portrait ? image.oriented(.left):image
        let size=DevelopmentPixelSize(width:Int(bandInput.extent.width),height:Int(bandInput.extent.height))
        let radii=try DevelopmentAdvancedDetailEngineV3.radii(sourceSize:size)
        var changed=bandInput
        if texture != 0 { changed=try DevelopmentAdvancedDetailEngineV3.applyBand(.texture,amount:texture*100,to:changed,radius:radii.texture) }
        if clarity != 0 { changed=try DevelopmentAdvancedDetailEngineV3.applyBand(.clarity,amount:clarity*100,to:changed,radius:radii.clarity) }
        if portrait { changed=changed.oriented(.right) }
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let grain=a.grain,grain>0 {
        let settings=DevelopmentEffectsV3(enabled:true,grain:grain,grainSize:a.grainSize,grainRoughness:a.grainRoughness)
        var grainArgs=Array(args.prefix(6))
        let filtered:CIImage?
        if let sourceGrainScale {
          guard sourceGrainScale>0,sourceGrainScale<=1 else {throw DevelopmentV3Error.invalidGraph}
          grainArgs.append(DevelopmentGrainSamplingEngineV1.colorGrainSettings(settings,scale:sourceGrainScale))
          if layer.kind == .subject {
            filtered=kernels.sourceGrain.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:1),arguments:grainArgs)
          } else {
            // Analytic masks only need the colour input. A second 1x1 sampler can collide
            // with another cached Core Image program after a long sequence of local edits.
            grainArgs.remove(at:1)
            filtered=try analyticalGrain.get().apply(extent:image.extent,roiCallback:{_,rect in rect},arguments:grainArgs)
          }
        } else {
          let noise=try DevelopmentGrainSamplingEngineV1.image(image.extent,effects:settings)
          grainArgs.insert(noise,at:1);grainArgs.append(grain)
          filtered=kernels.grain.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:grainArgs)
        }
        guard let output=filtered else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
        // The native-lattice kernel already composites its mask. Avoid asking Core Image
        // to fuse a second, neutral tonal kernel with a different argument layout.
        if sourceGrainScale != nil {
          var remaining=a
          remaining.grain=nil
          if remaining.isNeutral { continue }
        }
      }
      if let curves=a.curves,curves.enabled {
        var local=DevelopmentAdjustmentsV3();local.curves=curves
        let changed=try DevelopmentColorEngineV3.applyCurvesAndLevels(local,to:image)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let grading=a.grading,!grading.isNeutral {
        let changed=try DevelopmentColorEngineV2.apply(.init(grading:grading),to:image)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let lut = a.gradingLUT, lut.amount > 0 {
        let changed = try DevelopmentGradingLUTEngine.apply(lut, to: image)
        var compositeArgs = Array(args.prefix(6))
        compositeArgs.insert(changed, at: 1)
        guard let output = kernels.composite.apply(extent:image.extent, roiCallback:maskROI(layer, subject:subject, index:2),
                                                   arguments:compositeArgs) else { throw DevelopmentError.unreadable }
        image = output
        args[0] = image
      }
      if let defringe=a.defringe,defringe>0 {
        let local=DevelopmentOpticsV3(defringe:.init(enabled:true,purpleAmount:defringe*100,greenAmount:defringe*100))
        let changed=try DevelopmentDefringeEngineV3.apply(local,to:image)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      let sharpness=a.sharpness ?? 0,noiseReduction=a.noiseReduction ?? 0
      if sharpness>0 || noiseReduction>0 {
        var local=DevelopmentAdjustmentsV3()
        if sharpness>0 { local.sharpen = .init(enabled:true,intensity:sharpness) }
        if noiseReduction>0 { local.noiseReduction = .init(enabled:true,sourceCapability:.image,nonRawAmount:noiseReduction*5) }
        let mean = try nativeSharpenMean?.mean(for:image,at:.layer(layer.id))
        let changed=try DevelopmentGlobalEngineV3.apply(local,to:image,sourceIsRAW:false,preparedSharpMean:mean)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        usedNativeSharpenMean = mean != nil
        image=output;args[0]=image
      }
      if sharpness<0 {
        let changed=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:max(0.1,-sharpness*1.2)]).cropped(to:image.extent)
        var compositeArgs=Array(args.prefix(6));compositeArgs.insert(changed,at:1)
        guard let output=kernels.composite.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:compositeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let moire=a.moireReduction,moire>0 {
        let blurred=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:1.5]).cropped(to:image.extent)
        var moireArgs=Array(args.prefix(6));moireArgs.insert(blurred,at:1);moireArgs.append(moire)
        guard let output=kernels.moire.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:moireArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let dehaze=a.dehaze,dehaze != 0 {
        let radius=max(1,min(image.extent.width,image.extent.height)*0.01)
        let airlight=image.clampedToExtent().applyingFilter("CIGaussianBlur",parameters:[kCIInputRadiusKey:radius]).cropped(to:image.extent)
        var dehazeArgs=Array(args.prefix(6));dehazeArgs.insert(airlight,at:1);dehazeArgs.append(dehaze)
        guard let output=kernels.dehaze.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:dehazeArgs)else{throw DevelopmentError.unreadable}
        image=output;args[0]=image
      }
      if let sample=a.pointColor,sample.isActive {
        let (point,options)=Self.pointParameters(sample)
        var other = a
        other.pointColor = nil
        // Glow's compositing kernel applies tone after Glow. A Point Color-only layer can
        // also omit all four tonal vectors and preserve the original alpha and untouched RGB.
        let pointOnly = other.isNeutral || (a.glowAmount ?? 0) > 0
        let pointArgs = (pointOnly ? Array(args.prefix(6)) : args) + [point, options]
        let kernel = pointOnly ? kernels.pointColorOnly : kernels.pointColor
        guard let output=kernel.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:1),arguments:pointArgs)else{throw DevelopmentError.unreadable}
        image=output
        if let amount=a.glowAmount,amount>0 {
          var settings=sharedGlow ?? .init()
          settings.enabled=true;settings.amount=amount*100
          let glowed=try DevelopmentGlowEngineV3.apply(settings,to:image)
          var glowArgs=Array(args.prefix(10));glowArgs[0]=image;glowArgs.insert(glowed,at:1)
          guard let combined=kernels.glowLayer.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:glowArgs)else{throw DevelopmentError.unreadable}
          image=combined
        }
        // Without Glow, Point Color also applies tone in the same GPU pass.
        continue
      }
      if let amount=a.glowAmount,amount>0 {
        var settings=sharedGlow ?? .init()
        settings.enabled=true;settings.amount=amount*100
        let glowed=try DevelopmentGlowEngineV3.apply(settings,to:image)
        // The final kernel computes coverage from the pre-layer pixels, composites Glow, then
        // applies tone. No full-frame coverage texture or separate tonal pass is required.
        var glowArgs=args;glowArgs.insert(glowed,at:1)
        guard let output=kernels.glowLayer.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:2),arguments:glowArgs)else{throw DevelopmentError.unreadable}
        image=output
      }else{
        guard let output=kernels.layer.apply(extent:image.extent,roiCallback:maskROI(layer, subject:subject, index:1),arguments:args)else{throw DevelopmentError.unreadable}
        image=output
      }
    }
    if layers.count == 1, let layer = layers.first {
      previewHalfFIT?.bindPortableMaskGraph(input: input, layer: layer, output: image)
    }
    // Proxy inputs and parameters are validated and arithmetic is bounded; canonical retains this operator-level gate.
    if usedNativeSharpenMean {
      // The prepared source and mean bound the pure sharpen, its composite and the neutral tail above.
      try nativeSharpenMean?.requireCurrent()
    } else if !deferValidation, try previewHalfFIT?.validateAndPrepare(image,using:context) != true {
      if let canonicalValidation {
        let check = {
          try canonicalValidation.checkCancellation()
          try checkCancellation?()
        }
        switch canonicalValidation.transport {
        case .pairedTiles:
          try DevelopmentColorEngineV3.validateFinite(image,context:context,cacheClearCadence:.everyTwoTiles,checkCancellation:check)
        case .metalBands, .localNoiseBands:
          try DevelopmentCanonicalFiniteGPU.$residentPhotoWorkingBudget.withValue(DevelopmentCanonicalFiniteGPU.spatialWorkingBudget) {
            try DevelopmentColorEngineV3.validateFinite(image,context:context,checkCancellation:check)
          }
        case .pointwiseRegion, .pointwiseCompositeRegion:
          // These transports require the checked opaque RAW source. The original
          // hard radial blend cannot change any sample outside its support.
          let region = layers.count == 1 ? CanonicalValidation.pointwiseSupport(layers[0],extent:image.extent) : nil
          try DevelopmentColorEngineV3.validateFinite(image,context:context,region:region,checkCancellation:check)
        case .groupedFull:
          try DevelopmentColorEngineV3.validateFinite(image,context:context,
            scalarBatching:canonicalValidation.scalarBatching,checkCancellation:check)
        case .spatialTileRegion:
          if layers.count == 1, let region = CanonicalValidation.spatialTileSupport(layers[0], extent: image.extent, sourceGrainScale: sourceGrainScale) {
            try CanonicalPreviewDiagnostic.measure("validate native spatial mask tiles") {
              let adjustments = layers[0].adjustments
              let budget = (adjustments.texture ?? 0) > 0 && CanonicalValidation.textureRegionBandsEnabled &&
                canonicalValidation.scalarBatching == .clearAfterGroup
                ? DevelopmentCanonicalFiniteGPU.spatialWorkingBudget : nil
              try DevelopmentCanonicalFiniteGPU.$residentPhotoWorkingBudget.withValue(budget) {
                try DevelopmentColorEngineV3.validateFinite(image, context: context, cacheClearCadence: .everyTile,
                  region: region, scalarBatching:canonicalValidation.scalarBatching, checkCancellation: canonicalValidation.checkCancellation)
              }
            }
          } else {
            try DevelopmentColorEngineV3.validateFinite(image, context: context, checkCancellation: check)
          }
        }
      } else {
        try DevelopmentColorEngineV3.validateFinite(image, context: context, checkCancellation: checkCancellation)
      }
    }
    telemetryOutcome = .succeeded
    return image
  }

  private static let analyticalGrain:Result<CIKernel,Error> = Result {
    let source = try RAWMasterImageKernel.source(.maskAnalytic)
    guard let kernel=try CIKernel.kernels(withMetalString:source).first(where:{$0.name == "rmAnalyticalMaskGrain"}) else {throw DevelopmentError.unsupportedEngine}
    return kernel
  }
}
