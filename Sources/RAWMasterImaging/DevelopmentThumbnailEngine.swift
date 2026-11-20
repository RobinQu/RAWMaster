import Foundation
import CoreImage
import CryptoKit
import Metal
import RAWMasterCore

/// Opt-in synchronous metadata only. Nil callbacks do not construct records or scan pixels.
struct DevelopmentThumbnailDiagnosticRecord: Codable, Sendable {
  let stage: String
  let uptimeNanoseconds: UInt64
  let extentX,extentY,extentWidth,extentHeight: Double?
  let extentFinite: Bool?
  let width,height,rowBytes,allocationBytes,x,y,lane: Int?
  let valueKind,errorNamespace,errorCase: String?
  init(_ stage:String,extent:CGRect?=nil,width:Int?=nil,height:Int?=nil,rowBytes:Int?=nil,allocationBytes:Int?=nil,
       x:Int?=nil,y:Int?=nil,lane:Int?=nil,valueKind:String?=nil,error:Error?=nil) {
    self.stage=stage;uptimeNanoseconds=DispatchTime.now().uptimeNanoseconds
    func finite(_ v:CGFloat?)->Double?{guard let v,v.isFinite else{return nil};return Double(v)}
    extentX=finite(extent?.minX);extentY=finite(extent?.minY)
    extentWidth=finite(extent?.width);extentHeight=finite(extent?.height)
    extentFinite=extent.map{$0.minX.isFinite && $0.minY.isFinite && $0.width.isFinite && $0.height.isFinite}
    self.width=width;self.height=height;self.rowBytes=rowBytes;self.allocationBytes=allocationBytes
    self.x=x;self.y=y;self.lane=lane;self.valueKind=valueKind
    if let error {
      errorNamespace=String(reflecting:type(of:error))
      if error is DevelopmentThumbnailError || error is DevelopmentError || error is DevelopmentV3Error {
        errorCase=String(describing:error) // Closed enums only; never an NSError message/path.
      }else{let e=error as NSError;errorCase="domain="+e.domain+"/code="+String(e.code)}
    }else{errorNamespace=nil;errorCase=nil}
  }
}
enum DevelopmentThumbnailDiagnostic {
  typealias Callback=(DevelopmentThumbnailDiagnosticRecord)->Void
  static func trace<T>(_ stage:String,extent:CGRect?=nil,callback:Callback?,_ body:()throws->T) rethrows ->T {
    guard let callback else{return try body()}
    callback(.init(stage+".before",extent:extent))
    do{let result=try body();callback(.init(stage+".returned",extent:extent));return result}
    catch{callback(.init(stage+".threw",extent:extent,error:error));throw error}
  }
  static func nonfiniteKind(_ v:Float)->String {v.isNaN ? "NaN":(v.sign == .minus ? "negativeInfinity":"positiveInfinity")}
}

final class ThumbnailProxy: @unchecked Sendable {
  let surface:ThumbnailSurface
  let fingerprint:String
  let sourceBinding:DevelopmentLocalEditSourceBinding
  let sourceGeneration:UInt64
  let sourceIsRAW:Bool
  let bakedBaseEV:Float
  let affine:[Double]
  let preparationNanoseconds:UInt64
  let cold:Bool
  let scale:Double
  let contentRect:CGRect
  init(surface:ThumbnailSurface,fingerprint:String,sourceBinding:DevelopmentLocalEditSourceBinding,sourceGeneration:UInt64,sourceIsRAW:Bool,bakedBaseEV:Float,preparationNanoseconds:UInt64,cold:Bool){
    self.surface=surface;self.fingerprint=fingerprint;self.sourceBinding=sourceBinding;self.sourceGeneration=sourceGeneration
    self.sourceIsRAW=sourceIsRAW;self.bakedBaseEV=bakedBaseEV;self.preparationNanoseconds=preparationNanoseconds;self.cold=cold
    scale=min(1,256.0/Double(max(sourceBinding.orientedWidth,sourceBinding.orientedHeight)))
    contentRect=CGRect(x:0,y:0,width:Double(sourceBinding.orientedWidth)*scale,height:Double(sourceBinding.orientedHeight)*scale)
    affine=[scale,0,0,scale,0,0]
  }
}
/// All operations are invoked by the SAME Service native worker, one step then priority repump.
enum DevelopmentThumbnailEngine {
  static let version="rawmaster-thumbnail-compact-v3/linear-premul256/prefix-unbaked/source-scale-suffix/native-geometry/filter-v1/raw-nextup-alpha-roundoff-v1/adaptive-brilliance-illustrative-only-v1"
  static let filterOrder:[DevelopmentPhotoFilterV3]=[.original,.vivid,.vividWarm,.vividCool,.dramatic,.dramaticWarm,.dramaticCool,.mono,.silvertone,.noir]
  /// BW summary candidates replace the whole BW group via the existing resolver.
  /// Only their preparation input may omit that group; request identity stays original.
  static func proxyPreparationRecipe(_ request:DevelopmentThumbnailRequest)throws->DevelopmentRecipe {
    guard request.kind == .summary(.blackAndWhite) else{return request.preview.recipe}
    let analysis=DevelopmentAnalysisRequest(preview:request.preview,expectedRecipeFingerprint:request.expectedRecipeFingerprint,
      stage:.workingImageBeforeGeometry,operation:.summary(.blackAndWhite,amount:0),presentedRecipeFingerprint:request.presentedRecipeFingerprint)
    return try DevelopmentAnalysisEngine.samplingRecipe(analysis)
  }
  static func checkSupport(_ recipe:DevelopmentRecipe,sourceIsRAW:Bool = false)throws {
    guard recipe.adjustmentsV3 != nil else{throw DevelopmentThumbnailError.unsupportedGraph}
    var supportRecipe=recipe
    // Support projection ONLY: the actual filter is applied below, never removed from pixels.
    supportRecipe.adjustmentsV3!.filter = .init()
    // Thumbnails are already a separate approximation contract. Permit the new operator
    // here only; withSuffix explicitly computes it on this compact input, never main pixels.
    if DevelopmentBrillianceAdaptiveV1.isActive(supportRecipe.adjustmentsV3!.light) {
      supportRecipe.adjustmentsV3!.light.brillianceVersion=nil
    }
    guard try PreviewInteractiveProxyV3.support(supportRecipe,sourceIsRAW:sourceIsRAW) == .eligible else{throw DevelopmentThumbnailError.unsupportedGraph}
    _ = try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(recipe)
  }
  static func resourceVersion(_ request:DevelopmentThumbnailRequest)throws->String? {
    let active=request.preview.recipe.adjustmentsV3!.filter
    guard request.kind == .filters || (active.enabled && active.selection != .original && active.intensity != 0) else{return nil}
    let available=DevelopmentPhotoFilterEngineV3.capabilities()
    guard let version=available.resourceVersion,request.expectedPhotoFilterResourceVersion==version,
      (request.kind != .filters || Set(filterOrder)==available.filters) else{throw DevelopmentThumbnailError.unsupportedGraph}
    return version
  }
  /// Compact extent throughout; no view is stretched back to native dimensions.
  /// The scoped body may return owned output/scalars, never its borrowed CI graph.
  static func withSuffix<T>(_ recipe:DevelopmentRecipe,proxy:ThumbnailProxy,context:CIContext,geometry:Bool,
                            ledger:ThumbnailLedger? = nil,expectedResourceVersion:String? = nil,maximumPixel:Int = 256,diagnostic:DevelopmentThumbnailDiagnostic.Callback? = nil,_ body:(CIImage)throws->T)throws->T {
    try checkSupport(recipe,sourceIsRAW:proxy.sourceIsRAW);let p=recipe.adjustmentsV3!
    let filter=p.filter,active=filter.enabled && filter.selection != .original && filter.intensity != 0
    var tickets=[ThumbnailTicket](),held:DevelopmentPhotoFilterResourceStore.Pair?
    defer{context.clearCaches();if active{DevelopmentPhotoFilterResourceStore.shared.trimReady()};held=nil;for t in tickets{t.release()}}
    if let ledger{tickets.append(try ledger.reserve(65536,kind:.summary))}
    if DevelopmentBrillianceAdaptiveV1.isActive(p.light),let ledger {
      let bytes=DevelopmentBrillianceAdaptiveV1.mapWorkingBytes(proxy.contentRect)
      if bytes>0 {tickets.append(try ledger.reserve(bytes,kind:.summary))}
    }
    let resourceTicketStart=tickets.count
    if active {
      guard let ledger,let expectedResourceVersion else{throw DevelopmentThumbnailError.unsupportedGraph}
      // Reserve known loading scratch and exact table worst-case BEFORE resource lookup.
      tickets.append(try ledger.reserve(65536,kind:.summary))
      tickets.append(try ledger.reserve(DevelopmentPhotoFilterCatalog.payloadBytes,kind:.summary))
      if !DevelopmentPhotoFilterCatalog.intensities.contains(where:{Double($0)==filter.intensity}) && filter.intensity>1 {
        tickets.append(try ledger.reserve(DevelopmentPhotoFilterCatalog.payloadBytes,kind:.filters))
      }
      guard DevelopmentPhotoFilterEngineV3.capabilities().resourceVersion==expectedResourceVersion else{throw DevelopmentThumbnailError.staleSource}
    }
    return try proxy.surface.withImage{base in
      let nativeSize=CGSize(width:proxy.sourceBinding.orientedWidth,height:proxy.sourceBinding.orientedHeight)
      var image=base.cropped(to:proxy.contentRect)
      if proxy.sourceIsRAW {
        let ev=Float((p.legacyBasis?.exposureEV ?? 0)+(p.light.enabled ? 2*p.light.exposure:0)),delta=ev-proxy.bakedBaseEV
        if delta != 0{image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:Double(delta)])}
      }
      image=try DevelopmentThumbnailDiagnostic.trace("scalars.suffix",extent:image.extent,callback:diagnostic){
        try PreviewInteractiveProxyV3.suffix(p,source:image,sourceIsRAW:proxy.sourceIsRAW,nativeSize:nativeSize,scale:proxy.scale,context:context,check:{try Task.checkCancellation()},illustrativeAdaptiveBrilliance:true)
      }
      image=try DevelopmentPhotoFilterEngineV3.apply(filter,to:image,resourceLease:{pair in
        var ids=Set<ObjectIdentifier>(),bytes=0
        for atlas in [pair.lower,pair.upper] where ids.insert(ObjectIdentifier(atlas.buffer)).inserted{bytes+=atlas.bytes}
        guard pair.version==expectedResourceVersion,ids.count<=tickets.count-resourceTicketStart-1 else{throw DevelopmentThumbnailError.invalidEncoding}
        var seen=Set<ObjectIdentifier>(),i=resourceTicketStart+1
        for atlas in [pair.lower,pair.upper] where seen.insert(ObjectIdentifier(atlas.buffer)).inserted {
          try tickets[i].adjust(bytes:atlas.bytes,cpu:atlas.bytes,gpu:atlas.bytes)
          guard atlas.bytes<=DevelopmentPhotoFilterCatalog.payloadBytes else{throw DevelopmentThumbnailError.invalidEncoding};i+=1
        }
        guard bytes<=(tickets.count-resourceTicketStart-1)*DevelopmentPhotoFilterCatalog.payloadBytes else{throw DevelopmentThumbnailError.invalidEncoding}
        held=pair
      })
      try DevelopmentThumbnailDiagnostic.trace("scalars.local-validation",extent:image.extent,callback:diagnostic){try DevelopmentLocalEngineV3.validatePixels(image,context:context)}
      if geometry {
        let mapping=try PreviewInteractiveProxyV3.geometry(p.geometry,nativeSize:nativeSize,inputScale:proxy.scale,maxPixel:maximumPixel)
        image=PreviewInteractiveProxyV3.canvas(image.samplingLinear().transformed(by:mapping.transform),width:mapping.layout.width,height:mapping.layout.height)
      }
      let result=try body(image);withExtendedLifetime(held){};return result
    }
  }
  /// Thumbnail-only, unbaked image prefix. Caller supplies the <=256 owned source
  /// graph before its source-coordinate sampling view is expanded. The original
  /// legacyWB -> legacyEV -> absoluteWB order is retained; no new buffer is owned.
  static func imagePreamble(_ p:DevelopmentAdjustmentsV3,to base:CIImage,context:CIContext)throws->CIImage {
    guard base.extent.width>0,base.extent.height>0,base.extent.width<=256,base.extent.height<=256 else { throw DevelopmentThumbnailError.invalidEncoding }
    var image=base
    if let b=p.legacyBasis {
      if !p.whiteBalance.enabled,case let .temperatureTint(t,v)=b.whiteBalance {
        image=image.applyingFilter("CITemperatureAndTint",parameters:["inputNeutral":CIVector(x:t,y:v),"inputTargetNeutral":CIVector(x:6500,y:0)])
      }
      if b.exposureEV != 0 { image=image.applyingFilter("CIExposureAdjust",parameters:[kCIInputEVKey:b.exposureEV]) }
    }
    return try DevelopmentWhiteBalanceEngineV3.applyImage(p.whiteBalance,to:image,context:context)
  }
  static func scaled(_ image:CIImage,maximum:Int)throws->CIImage {
    let e=image.extent
    guard e.width.isFinite,e.height.isFinite,e.width>=1,e.height>=1,!e.isInfinite else{throw DevelopmentThumbnailError.invalidEncoding}
    let f=min(1,Double(maximum)/max(e.width,e.height))
    let w=max(1,Int(floor(e.width*f))),h=max(1,Int(floor(e.height*f)))
    return image.transformed(by:.init(translationX:-e.minX,y:-e.minY)).transformed(by:.init(scaleX:Double(w)/e.width,y:Double(h)/e.height)).cropped(to:CGRect(x:0,y:0,width:w,height:h))
  }
  static func context(device:MTLDevice)->CIContext {CIContext(mtlDevice:device,options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])}
  static func withContext<T>(ledger:ThumbnailLedger,device:MTLDevice,contextOwner:ThumbnailWorkerContextV1? = nil,_ body:(CIContext)throws->T)throws->T {
    if let contextOwner{return try contextOwner.withContext(ledger:ledger,device:device,body)}
    let scratch=try ledger.reserve(2*1024*1024,kind:.summary);defer{scratch.release()}
    // Conservative RESERVED bookkeeping only. CI-private allocations are unknown, not actual2MiB GPU bytes.
    return try autoreleasepool{let value=context(device:device);defer{value.clearCaches()};return try body(value)}
  }
  static func statistics(_ image:CIImage,ledger:ThumbnailLedger,device:MTLDevice,context:CIContext? = nil,diagnostic:DevelopmentThumbnailDiagnostic.Callback? = nil)throws->DevelopmentAnalysisScalars {
    let graph=try DevelopmentThumbnailDiagnostic.trace("scalars.statistics.scale",extent:image.extent,callback:diagnostic){try scaled(image,maximum:128)},e=graph.extent
    diagnostic?(.init("scalars.statistics.scaled",extent:e))
    let owner=try DevelopmentThumbnailDiagnostic.trace("scalars.statistics.allocate",extent:e,callback:diagnostic){try ThumbnailSurface(width:Int(e.width),height:Int(e.height),float:true,kind:.summary,ledger:ledger,device:device,diagnostic:diagnostic)}
    defer{owner.finishProducer();owner.retire()}
    if let context{try owner.fill(graph,context:context,diagnostic:diagnostic)}else{try withContext(ledger:ledger,device:device){try owner.fill(graph,context:$0,diagnostic:diagnostic)}};owner.finishProducer()
    return try owner.withFloatPixels(diagnostic:diagnostic){base,row in
      var bins=Array(repeating:[UInt64](repeating:0,count:256),count:4),visible=0,transparent=0
      var sum=SIMD3<Double>(repeating:0),saturation=0.0
      func bin(_ v:Double)->Int{Int((min(1,max(0,v))*255).rounded(.down))}
      for y in 0..<owner.height{let p=base.advanced(by:y*row).assumingMemoryBound(to:Float.self)
        for x in 0..<owner.width{let n=x*4;guard (0..<4).allSatisfy({p[n+$0].isFinite})else{
          if let diagnostic,let lane=(0..<4).first(where:{!p[n+$0].isFinite}) {
            diagnostic(.init("scalars.statistics.first-nonfinite",x:x,y:y,lane:lane,valueKind:DevelopmentThumbnailDiagnostic.nonfiniteKind(p[n+lane])))
          }
          throw DevelopmentThumbnailError.invalidEncoding
        }
          let a=Double(p[n+3]);if a<=0{transparent+=1;continue}
          let c=SIMD3(Double(p[n]),Double(p[n+1]),Double(p[n+2]))/a
          let enc=SIMD3(DevelopmentColorEngineV2.encode(c.x),DevelopmentColorEngineV2.encode(c.y),DevelopmentColorEngineV2.encode(c.z))
          let top=max(enc.x,max(enc.y,enc.z)),bottom=min(enc.x,min(enc.y,enc.z))
          bins[0][bin(enc.x)]+=1;bins[1][bin(enc.y)]+=1;bins[2][bin(enc.z)]+=1;bins[3][bin(DevelopmentColorEngineV2.encode(DevelopmentColorEngineV2.luma(c)))]+=1
          sum+=c;saturation+=min(1,max(0,(top-bottom)/max(abs(top),1e-4)));visible+=1
        }
      }
      if visible>0{sum/=Double(visible);saturation/=Double(visible)}
      return .init(histogram:.init(red:bins[0],green:bins[1],blue:bins[2],luminance:bins[3],visibleSamples:visible,transparentSamples:transparent,sampledSize:.init(width:owner.width,height:owner.height)),meanLinearRGB:sum,meanSaturation:saturation)
    }
  }
  static func prepareScalars(_ request:DevelopmentThumbnailRequest,proxy:ThumbnailProxy,ledger:ThumbnailLedger,device:MTLDevice,contextOwner:ThumbnailWorkerContextV1? = nil,diagnostic:DevelopmentThumbnailDiagnostic.Callback? = nil)throws->DevelopmentAnalysisScalars {
    guard case .summary(let group)=request.kind else{throw DevelopmentThumbnailError.unsupportedGraph}
    let analysis=DevelopmentAnalysisRequest(preview:request.preview,expectedRecipeFingerprint:request.expectedRecipeFingerprint,stage:.workingImageBeforeGeometry,operation:.summary(group,amount:0),presentedRecipeFingerprint:request.presentedRecipeFingerprint)
    let recipe=try DevelopmentThumbnailDiagnostic.trace("scalars.projection",callback:diagnostic){try DevelopmentAnalysisEngine.samplingRecipe(analysis)}
    return try DevelopmentThumbnailDiagnostic.trace("scalars.prepare",callback:diagnostic){
      try withContext(ledger:ledger,device:device,contextOwner:contextOwner){context in try withSuffix(recipe,proxy:proxy,context:context,geometry:false,ledger:ledger,expectedResourceVersion:request.expectedPhotoFilterResourceVersion,diagnostic:diagnostic){image in
        try DevelopmentThumbnailDiagnostic.trace("scalars.statistics",extent:image.extent,callback:diagnostic){try statistics(image,ledger:ledger,device:device,context:context,diagnostic:diagnostic)}
      }}
    }
  }
  static func resolveCandidate(_ request:DevelopmentThumbnailRequest,index:Int,scalars:DevelopmentAnalysisScalars,source:DevelopmentLocalEditSourceBinding,sourceIsRAW:Bool)throws->DevelopmentRecipe {
    if request.kind == .filters {
      guard filterOrder.indices.contains(index)else{throw DevelopmentThumbnailError.invalidRequest}
      return try request.preview.recipe.applying(.setParameters(.filter(.init(enabled:index != 0,selection:filterOrder[index],intensity:100))),context:.init(source:source,sourceGeneration:request.preview.sourceGeneration,analysisStage:.workingImageBeforeGeometry,sourceCapability:sourceIsRAW ? .raw:.image))
    }
    guard case .summary(let group)=request.kind,(0..<5).contains(index)else{throw DevelopmentThumbnailError.unsupportedGraph}
    let parameters=try DevelopmentAnalysisEngine.resolvedSummary(group,amount:[-1.0,-0.5,0,0.5,1][index],scalars:scalars)
    return try request.preview.recipe.applying(.setParameters(parameters),context:.init(source:source,sourceGeneration:request.preview.sourceGeneration,analysisStage:.workingImageBeforeGeometry,sourceCapability:sourceIsRAW ? .raw:.image))
  }
  static func tile(_ request:DevelopmentThumbnailRequest,index:Int,scalars:DevelopmentAnalysisScalars?,proxy:ThumbnailProxy,ledger:ThumbnailLedger,device:MTLDevice,contextOwner:ThumbnailWorkerContextV1? = nil)throws->(ThumbnailSurface,DevelopmentThumbnailTileDescriptor,Float) {
    guard index>=0,index<request.kind.count else{throw DevelopmentThumbnailError.invalidRequest}
    _ = try resourceVersion(request)
    let amount:Double? = request.kind == .filters ? nil:[-1.0,-0.5,0,0.5,1][index]
    let actualScalars:DevelopmentAnalysisScalars
    if let scalars{actualScalars=scalars}else if request.kind == .filters{
      let bins=[UInt64](repeating:0,count:256)
      actualScalars = .init(histogram:.init(red:bins,green:bins,blue:bins,luminance:bins,visibleSamples:0,transparentSamples:0,sampledSize:.init(width:1,height:1)),meanLinearRGB:.zero,meanSaturation:0)
    }else{throw DevelopmentThumbnailError.invalidRequest}
    let candidate=try resolveCandidate(request,index:index,scalars:actualScalars,source:proxy.sourceBinding,sourceIsRAW:proxy.sourceIsRAW)
    let p=candidate.adjustmentsV3!,ev=Float((p.legacyBasis?.exposureEV ?? 0)+(p.light.enabled ? 2*p.light.exposure:0))
    var created:ThumbnailSurface?
    do {
      let result=try withContext(ledger:ledger,device:device,contextOwner:contextOwner){context in try withSuffix(candidate,proxy:proxy,context:context,geometry:true,ledger:ledger,expectedResourceVersion:request.expectedPhotoFilterResourceVersion,maximumPixel:request.target.maximumPixel){graph in
        let image=graph
        guard image.extent.minX==0,image.extent.minY==0,image.extent==image.extent.integral,max(image.extent.width,image.extent.height)<=Double(request.target.maximumPixel)else{throw DevelopmentThumbnailError.invalidEncoding}
        try DevelopmentColorEngineV3.validateFinite(image,context:context)
        guard let destinationICC=PhotoRenderer.sRGB.copyICCData() as Data?,!destinationICC.isEmpty else{throw DevelopmentThumbnailError.invalidEncoding}
        let owner=try ThumbnailSurface(width:Int(image.extent.width),height:Int(image.extent.height),float:false,kind:request.kind == .filters ? .filters:.summary,ledger:ledger,device:device)
        created=owner;try owner.fill(image,context:context)
        let receipt=DevelopmentThumbnailTileDescriptor(index:index,summaryAmount:amount,filter:request.kind == .filters ? filterOrder[index]:nil,actualRecipe:candidate,actualRecipeFingerprint:try EditingFingerprint.of(candidate),width:owner.width,height:owner.height,allocation:owner.allocation,storageFormat:"rgba8Unorm/top-row-first",
          destinationColorSpace:(PhotoRenderer.sRGB.name as String?) ?? "sRGB",
          destinationICCProfileSHA256:SHA256.hash(data:destinationICC).map{String(format:"%02x",$0)}.joined(),alphaPolicy:"premultiplied")
        return(owner,receipt,ev)
      }}
      result.0.finishProducer();return result // All CI/context aliases have now drained.
    }catch{created?.finishProducer();created?.retire();throw error}
  }
}
