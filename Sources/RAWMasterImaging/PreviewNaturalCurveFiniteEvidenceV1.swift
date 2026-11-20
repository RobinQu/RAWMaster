import Foundation
import CoreImage
import Metal
import CryptoKit
import RAWMasterCore

/// Distinct QA-only contract. No pointwise-prefix substitution and no export/analysis admission.
final class PreviewNaturalCurveFiniteEvidenceV1 {
  static let version="canonical-natural-curves-alpha1-f32-half-lut-finite-v1"
  static let stage="global-output-after-photo-filter"
  static let samplerVersion="natural-native-identity-or-positive-linear-closed-envelope-v1"
  static let expectedKernelSHA256="d85ab63cbb52343f09b58014d50d5c7e92891426b0f1b8a7c561aa989b647744"
  static func digest(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  static var kernelSHA256:String{digest(Data(DevelopmentNaturalCubicCurvesV1.metalSource.utf8))}
  static func bootstrap(bundleIdentifier:String?,environment:[String:String])->Bool {
    bundleIdentifier=="io.robinqu.RAWMaster.preview022" && environment["RAWMASTER_QA_NATIVE_POINTWISE_V1"]=="1" &&
      environment["RAWMASTER_QA_NATURAL_CURVE_FINITE_V1"]=="1"
  }
  /// All Double payload bits, including dormant parameters and signed zero, in stored-field order.
  /// This is an in-process/versioned cache binding, not a new persisted recipe encoding.
  static func doubleBits(_ value:Any)->[UInt64]? {
    var result=[UInt64](),nodes=0,stringBytes=0
    func collect(_ value:Any)->Bool {
      nodes+=1;guard nodes<=4096 else{return false}
      if let text=value as? String {let count=text.utf8.prefix(32769).count;stringBytes+=count;return stringBytes<=32768}
      if let d=value as? Double {guard result.count<512 else{return false};result.append(d.bitPattern);return true}
      for child in Mirror(reflecting:value).children {if !collect(child.value){return false}}
      return true
    }
    return collect(value) ? result:nil
  }
  static func metadataFits(_ recipe:DevelopmentRecipe)throws->Bool {
    guard doubleBits(recipe) != nil else{return false}
    let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
    return try encoder.encode(recipe).count<=65536
  }
  struct Binding:Equatable,Encodable {
    let recipeFingerprint:String,curvesFingerprint:String,parameterBits:[UInt64],lutSHA256:String,kernelSHA256:String,operatorVersion:String
    init(_ recipe:DevelopmentRecipe)throws {
      try recipe.validate();guard let p=recipe.adjustmentsV3 else{throw DevelopmentV3Error.invalidGraph}
      guard let bits=PreviewNaturalCurveFiniteEvidenceV1.doubleBits(recipe),try PreviewNaturalCurveFiniteEvidenceV1.metadataFits(recipe) else{throw PreviewPresentationError.unsupported}
      recipeFingerprint=try EditingFingerprint.of(recipe);curvesFingerprint=try EditingFingerprint.of(p.curves);parameterBits=bits
      lutSHA256=PreviewNaturalCurveFiniteEvidenceV1.digest(try DevelopmentNaturalCubicCurvesV1.tables(p.curves).data)
      kernelSHA256=PreviewNaturalCurveFiniteEvidenceV1.kernelSHA256;operatorVersion=DevelopmentNaturalCubicCurvesV1.operatorVersion
    }
  }
  static func domain(_ recipe:DevelopmentRecipe,size:CGSize)throws->Bool {
    try recipe.validate();guard recipe.schemaVersion==3,let p=recipe.adjustmentsV3,
      p.curves.algorithm == .naturalCubicGamma512LumaV1,DevelopmentColorEngineV3.curvesActive(p.curves),try metadataFits(recipe),
      p.legacyBasis?.isPixelNeutral ?? true,
      !DevelopmentSpatialEngineV3.isActive(p.light),!DevelopmentColorEngineV3.pointwiseActive(p),
      !(p.light.enabled && p.light.exposure != 0),
      !p.whiteBalance.enabled || p.whiteBalance.adjustment == .asShot,
      !p.noiseReduction.enabled, // Enabled RAW NR reconfigures native defaults even at zero amounts.
      DevelopmentNaturalCurvePickerV1.supports(p,sourceIsRAW:true) else{return false}
    // Match the actual native parameter arithmetic, including IEEE signed zero.
    // A legal -0 effective EV is outside this +0 native-base contract and keeps the original scan.
    let effectiveEV=(p.legacyBasis?.exposureEV ?? 0)+(p.light.enabled ? 2*p.light.exposure:0)
    guard Float(effectiveEV).bitPattern==Float(0).bitPattern else{return false}
    var rest=p
    rest.legacyBasis=nil;rest.light = .init();rest.color = .init();rest.blackAndWhite = .init()
    rest.whiteBalance = .init();rest.curves = .init();rest.levels = .init();rest.definition = .init()
    rest.selectiveColor = .init();rest.noiseReduction = .init();rest.sharpen = .init();rest.vignette = .init()
    rest.filter = .init();rest.localEdits = .init();rest.advancedDetail = .init()
    // Existing identity geometry closure; original geometry itself is never altered.
    return try PreviewNativePointwiseV1.saturationDomainReason(.init(adjustmentsV3:rest),size:size)==nil
  }
  static func verify(_ recipe:DevelopmentRecipe,native:PreviewNativeSource,descriptor:PreviewNativePointwiseBaseDescriptorV1)throws {
    guard native.hasRAWFilter,try domain(recipe,size:native.nativeSize),let p=recipe.adjustmentsV3,
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
      case .rawDefaults(let defaults)=descriptor.source else{throw PreviewPresentationError.allocationProtocol}
    let parameters=try DevelopmentRendererV3.NativeParameters(p,originalDefaultsFingerprint:defaults)
    guard defaults==native.originalNativeDefaultsFingerprint,parameters.exposure.bitPattern==Float(0).bitPattern,
      parameters.whiteBalance == .asShot,parameters.noiseReduction==nil else{throw PreviewPresentationError.unsupported}
  }
  static func sampler(owner:UUID,authority:String,grid:PreviewNativePointwiseCertificateV1.Grid,descriptor:PreviewNativePointwiseBaseDescriptorV1)->PreviewNativePointwiseCertificateV1.Sampler {
    .init(owner:owner,authority:authority,grid:grid,device:descriptor.deviceRegistryID,pointSHA256:kernelSHA256,
      witnessSHA256:PreviewNativePointwiseCertificateV1.witnessSHA256,samplerABI:samplerVersion,os:descriptor.os,
      optionsVersion:PreviewNativePointwiseV1.contextVersion)
  }
  static func validTableData(_ data:Data)->Bool {
    guard data.count==DevelopmentNaturalCubicCurvesV1.tableBytes else{return false}
    let maximum=Float(Float16(powf(2,2.2)))
    return data.withUnsafeBytes{bytes in
      let half=bytes.bindMemory(to:UInt16.self)
      for i in stride(from:0,to:half.count,by:4) {
        let r=Float(Float16(bitPattern:half[i]))
        if !r.isFinite || r<0 || r>maximum || half[i+1] != half[i] || half[i+2] != half[i] || half[i+3] != Float16(1).bitPattern{return false}
      };return true
    }
  }
  static func acceptsLUT(data:Data,kernelSHA:String,curvesFingerprint:String,binding:Binding)->Bool {
    validTableData(data) && digest(data)==binding.lutSHA256 && kernelSHA==binding.kernelSHA256 &&
      kernelSHA==expectedKernelSHA256 && curvesFingerprint==binding.curvesFingerprint
  }
  private weak var native:PreviewNativeSource?,pin:RawBasePin?,contextOwner:PreviewCanonicalFiniteContextV1?,base:CIImage?
  private let descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid
  private let owner:UUID,authority:String,binding:Binding,sampler:PreviewNativePointwiseCertificateV1.Sampler
  let syntheticOnly:Bool
  private var active=true
  private(set) var consumed=false,consumptionCount=0
  private var artifact:DevelopmentNaturalCubicCurvesV1.ActualLUTWitness?
  private weak var actualOutput:CIImage?
  private var recorded=false,recordMismatch=false
  private(set) var actualLUTSHA256:String?
  private(set) var bindingFingerprint:String?
  private init(native:PreviewNativeSource,pin:RawBasePin,base:CIImage,contextOwner:PreviewCanonicalFiniteContextV1,
               descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid,
               owner:UUID,authority:String,binding:Binding,sampler:PreviewNativePointwiseCertificateV1.Sampler,syntheticOnly:Bool) {
    self.native=native;self.pin=pin;self.base=base;self.contextOwner=contextOwner;self.descriptor=descriptor;self.grid=grid
    self.owner=owner;self.authority=authority;self.binding=binding;self.sampler=sampler;self.syntheticOnly=syntheticOnly
  }
  static func withEvidence<T>(native:PreviewNativeSource,pin:RawBasePin,base:CIImage,contextOwner:PreviewCanonicalFiniteContextV1?,descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid,recipe:DevelopmentRecipe,check:()throws->Void,_ body:(PreviewNaturalCurveFiniteEvidenceV1?)throws->T)throws->T {
    try withFactory(native:native,pin:pin,base:base,contextOwner:contextOwner,descriptor:descriptor,grid:grid,recipe:recipe,syntheticOnly:false,check:check,body)
  }
  /// Internal tests only: real tiny storage scan/witness, without claiming a RAW decoder/source qualification.
  /// Service and production preview call only withEvidence, which insists on actual hasRAWFilter.
  static func withSyntheticEvidenceForTesting<T>(native:PreviewNativeSource,pin:RawBasePin,base:CIImage,contextOwner:PreviewCanonicalFiniteContextV1?,descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid,recipe:DevelopmentRecipe,check:()throws->Void,_ body:(PreviewNaturalCurveFiniteEvidenceV1?)throws->T)throws->T {
    guard !native.hasRAWFilter,descriptor.width*descriptor.height<=65536 else{throw PreviewPresentationError.unsupported}
    return try withFactory(native:native,pin:pin,base:base,contextOwner:contextOwner,descriptor:descriptor,grid:grid,recipe:recipe,syntheticOnly:true,check:check,body)
  }
  private static func withFactory<T>(native:PreviewNativeSource,pin:RawBasePin,base:CIImage,contextOwner:PreviewCanonicalFiniteContextV1?,descriptor:PreviewNativePointwiseBaseDescriptorV1,grid:PreviewNativePointwiseCertificateV1.Grid,recipe:DevelopmentRecipe,syntheticOnly:Bool,check:()throws->Void,_ body:(PreviewNaturalCurveFiniteEvidenceV1?)throws->T)throws->T {
    guard let contextOwner else{return try body(nil)}
    try check();try native.validateCaptureAuthority()
    guard syntheticOnly || native.hasRAWFilter,try domain(recipe,size:native.nativeSize),kernelSHA256==expectedKernelSHA256,
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
      grid == (try PreviewNativePointwiseCertificateV1.grid(width:descriptor.width,height:descriptor.height)),grid.envelopeClosed,
      contextOwner.deviceRegistryID==descriptor.deviceRegistryID,contextOwner.optionsVersion==PreviewNativePointwiseV1.contextVersion,
      contextOwner.context.workingFormat == .RGBAf,let space=contextOwner.context.workingColorSpace,CFEqual(space,DevelopmentColorEngineV3.linearSRGB),
      let owner=pin.ownerIncarnation,let input=pin.pointwiseInputCertificate,input.owner==owner,input.eligible,
      input.maximumAbsoluteRGB.isFinite,input.maximumAbsoluteRGB<=PreviewNativePointwiseCertificateV1.bound,
      input.pixels==descriptor.width*descriptor.height,base === (try pin.image),base.extent==CGRect(x:0,y:0,width:descriptor.width,height:descriptor.height) else{return try body(nil)}
    if !syntheticOnly{try verify(recipe,native:native,descriptor:descriptor)}
    let authority=try descriptor.fingerprint(),sampler=sampler(owner:owner,authority:try descriptor.fingerprint(),grid:grid,descriptor:descriptor)
    guard input.authority==authority,pin.pointwiseSamplerCertificate==sampler else{return try body(nil)}
    let e=try PreviewNaturalCurveFiniteEvidenceV1(native:native,pin:pin,base:base,contextOwner:contextOwner,descriptor:descriptor,grid:grid,owner:owner,authority:authority,binding:Binding(recipe),sampler:sampler,syntheticOnly:syntheticOnly)
    defer{e.active=false;e.artifact=nil}
    try check();try native.validateCaptureAuthority();return try body(e)
  }
  /// The witness is created by the engine from the exact tables/CIImage used in that kernel invocation.
  func recordActualLUT(_ value:DevelopmentNaturalCubicCurvesV1.ActualLUTWitness,output:CIImage) {
    guard active,!consumed,!recorded else{recordMismatch=true;return};recorded=true
    guard Self.acceptsLUT(data:value.data,kernelSHA:value.kernelSHA256,curvesFingerprint:value.recipeCurvesFingerprint,binding:binding),
      value.lookup.extent==CGRect(x:0,y:0,width:512,height:4) else{recordMismatch=true;return}
    artifact=value;actualOutput=output;actualLUTSHA256=Self.digest(value.data)
  }
  func consumeGlobalOutput(recipe:DevelopmentRecipe,capture:URL,context:CIContext,suppliedBase:CIImage?,sourceIsRAW:Bool,sourceSize:CGSize,output:CIImage,check:(()throws->Void)?)throws->Bool {
    guard active,!consumed,!recordMismatch,recorded,let artifact,let native,let pin,let contextOwner,let base,actualOutput === output else{return false}
    try check?();try native.validateCaptureAuthority()
    guard capture==native.capture,sourceIsRAW==native.hasRAWFilter,(syntheticOnly || sourceIsRAW),sourceSize==native.nativeSize,
      context === contextOwner.context,suppliedBase === base,context.workingFormat == .RGBAf,
      let space=context.workingColorSpace,CFEqual(space,DevelopmentColorEngineV3.linearSRGB),
      contextOwner.deviceRegistryID==descriptor.deviceRegistryID,contextOwner.optionsVersion==PreviewNativePointwiseV1.contextVersion,
      try Self.domain(recipe,size:sourceSize),binding == (try Binding(recipe)),Self.kernelSHA256==Self.expectedKernelSHA256,
      artifact.kernelSHA256==Self.kernelSHA256,Self.digest(artifact.data)==binding.lutSHA256,Self.validTableData(artifact.data),
      descriptor == (try PreviewNativePointwiseBaseV1.descriptor(native,sourceKey:descriptor.sourceKey,generation:descriptor.generation,verifiedContentID:descriptor.verifiedContentID)),
      grid == (try PreviewNativePointwiseCertificateV1.grid(width:descriptor.width,height:descriptor.height)),grid.envelopeClosed,
      pin.ownerIncarnation==owner,let input=pin.pointwiseInputCertificate,input.owner==owner,input.authority==authority,input.eligible,
      input.pixels==descriptor.width*descriptor.height,input.maximumAbsoluteRGB.isFinite,input.maximumAbsoluteRGB<=PreviewNativePointwiseCertificateV1.bound,
      pin.pointwiseSamplerCertificate==sampler,base === (try pin.image) else{return false}
    if !syntheticOnly{try Self.verify(recipe,native:native,descriptor:descriptor)}
    struct Identity:Encodable {let version,stage,authority,options:String;let owner:UUID;let binding:Binding;let generation,device:UInt64;let synthetic:Bool}
    bindingFingerprint=try EditingFingerprint.of(Identity(version:Self.version,stage:Self.stage,authority:authority,options:contextOwner.optionsVersion,owner:owner,binding:binding,generation:descriptor.generation,device:descriptor.deviceRegistryID,synthetic:syntheticOnly))
    try check?();try native.validateCaptureAuthority();consumed=true;consumptionCount+=1;return true
  }
}
final class PreviewNaturalCurveFiniteObservation {var joinedGlobalScans=0}
