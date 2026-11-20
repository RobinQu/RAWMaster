import AppKit
import CoreImage
import CryptoKit
import Foundation
import RAWMasterCore

/// Explicit fixed-amount QA operator. No prepared source or full CI graph escapes one invocation.
enum DevelopmentBrilliancePublicV1 {
  static let version = "brilliance-public-tiled-joint-fixed050-v1"
  static func makeContext()->CIContext {CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,.workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])}
  static let transportVersion = "brilliance-public-CG16-whole-viewport-bank128-v1"
  static func bootstrap(bundleIdentifier:String?,environment:[String:String])->Bool {
    bundleIdentifier == "io.robinqu.RAWMaster.preview022" && environment["RAWMASTER_QA_BRILLIANCE_PUBLIC_V1"] == "1"
  }
  static func active(_ recipe:DevelopmentRecipe)->Bool {
    guard let p=recipe.adjustmentsV3 else{return false}
    return p.light.brillianceVersion == .publicTiledJointFixed050V1 && p.light.enabled && p.light.brilliance != 0
  }
  static func requireDomain(_ p:DevelopmentAdjustmentsV3,sourceIsRAW:Bool)throws {
    guard #available(macOS 26.0,*)else{throw DevelopmentV3Error.unsupportedAdjustment(.light)}
    guard !sourceIsRAW,p.light.brillianceVersion == .publicTiledJointFixed050V1,
      p.light.enabled,p.light.brilliance == 0.5,p.light.exposure == 0,p.light.highlights == 0,
      p.light.shadows == 0,p.light.brightness == 0,p.light.contrast == 0,p.light.blackPoint == 0,
      p.legacyBasis?.isPixelNeutral ?? true else {throw DevelopmentV3Error.unsupportedAdjustment(.light)}
    var geometry=p.geometry;geometry.version = .adjustV3
    guard geometry == DevelopmentGeometryV3() else{throw DevelopmentV3Error.unsupportedGeometry}
    var rest=p;rest.light = .init();rest.geometry = .init();rest.legacyBasis=nil
    guard rest == DevelopmentAdjustmentsV3() else{throw DevelopmentV3Error.unsupportedAdjustment(.light)}
  }
  struct Observation {
    let requestID:UUID
    let version,transport,mapSHA256,sourceSHA256,prefixFingerprint:String
    let nativePixels:Int
  }
  struct Request {
    let id=UUID()
    let scope:PreviewPresentationScope
    let check:()throws->Void
    func requireCurrent()throws{try check();try scope.requireOpenAdmission()}
  }
  struct InputValidationObservation: Sendable {
    let requestID: UUID
    let beganNS, validationReturnedNS, retiredNS: UInt64
    let validatedPixels: Int?
    let validationSucceeded, wrapperNil: Bool
  }
  /// One optional QA scalar per invocation, bounded across the whole process.
  /// Neither this sink nor the observation owns an image, context, task or error.
  private final class InputValidationScalarSink: @unchecked Sendable {
    static let shared = InputValidationScalarSink()
    private let lock = NSLock()
    private var count = 0
    private var overflow = false
    func emit(_ value: InputValidationObservation) {
      guard ProcessInfo.processInfo.environment["RAWMASTER_BRILLIANCE_INPUT_CONTEXT_QA_SCALARS"] == "1" else { return }
      lock.lock();defer { lock.unlock() }
      guard count < 64 else {
        if !overflow { overflow = true; write(["kind":"overflow","recordLimit":64]) }
        return
      }
      count += 1
      write(["kind":"input-validation-retired","requestID":value.requestID.uuidString,
        "beganNS":value.beganNS,"validationReturnedNS":value.validationReturnedNS,"retiredNS":value.retiredNS,
        "validatedPixels":value.validatedPixels as Any? ?? NSNull(),
        "validationSucceeded":value.validationSucceeded,"wrapperNil":value.wrapperNil,
        "privateCIPhysicalReleaseProven":false])
    }
    private func write(_ fields: [String:Any]) {
      var fields = fields;fields["tag"] = "rawmaster-brilliance-input-context"
      guard var bytes = try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) else { return }
      bytes.append(0x0a);try? FileHandle.standardError.write(contentsOf:bytes)
    }
  }
  struct OutputValidationBandObservation: Sendable {
    let requestID: UUID
    let bandIndex, firstRow, rows, validatedPixels: Int
    let nativeTaskStarted: Bool
    let nativeJoinedNS: UInt64?
    let poolExitedNS, clearReturnedNS: UInt64
  }
  /// Pure scalar QA evidence; no native resources or validation errors are retained.
  private final class OutputValidationScalarSink: @unchecked Sendable {
    static let shared = OutputValidationScalarSink()
    private let lock = NSLock()
    private var count = 0
    private var overflow = false
    func emit(_ value: OutputValidationBandObservation) {
      guard ProcessInfo.processInfo.environment["RAWMASTER_BRILLIANCE_OUTPUT_BAND_QA_SCALARS"] == "1" else { return }
      lock.lock();defer { lock.unlock() }
      guard count < 256 else {
        if !overflow { overflow = true; write(["kind":"overflow","recordLimit":256]) }
        return
      }
      count += 1
      write(["kind":"output-validation-band-cleared","requestID":value.requestID.uuidString,
        "bandIndex":value.bandIndex,"firstRow":value.firstRow,"rows":value.rows,
        "validatedPixels":value.validatedPixels,"nativeTaskStarted":value.nativeTaskStarted,
        "nativeJoinedNS":value.nativeJoinedNS as Any? ?? NSNull(),
        "poolExitedNS":value.poolExitedNS,"clearReturnedNS":value.clearReturnedNS,
        "privateCIPhysicalReleaseProven":false])
    }
    private func write(_ fields: [String:Any]) {
      var fields = fields;fields["tag"] = "rawmaster-brilliance-output-band"
      guard var bytes = try? JSONSerialization.data(withJSONObject:fields,options:[.sortedKeys]) else { return }
      bytes.append(0x0a);try? FileHandle.standardError.write(contentsOf:bytes)
    }
  }
  /// End the input scan's owned context before map generation and output evaluation.
  /// The original scan, task waits, domain and readback reservation are unchanged.
  static func validateInputWithOwnedContext(_ image: CIImage, request: Request,
    observeForTesting: ((InputValidationObservation) -> Void)? = nil) throws -> Int {
    let began = DispatchTime.now().uptimeNanoseconds
    var returned: UInt64 = 0
    weak var witness: CIContext?
    let result: Result<Int,Error> = autoreleasepool {
      let owned = makeContext();witness = owned
      defer { owned.clearCaches() }
      let result = Result { try validateOpaque(image,context:owned,request:request,input:true) }
      returned = DispatchTime.now().uptimeNanoseconds
      return result
    }
    let count = try? result.get()
    let observation = InputValidationObservation(requestID:request.id,beganNS:began,
      validationReturnedNS:returned,retiredNS:DispatchTime.now().uptimeNanoseconds,
      validatedPixels:count,validationSucceeded:count != nil,wrapperNil:witness == nil)
    InputValidationScalarSink.shared.emit(observation);observeForTesting?(observation)
    guard observation.wrapperNil else {
      if case .failure(let primary) = result {
        throw NSError(domain:"RAWMaster.BrillianceInputContextCleanup",code:1,
          userInfo:[NSUnderlyingErrorKey:primary,"cleanupError":PreviewPresentationError.allocationProtocol])
      }
      throw PreviewPresentationError.allocationProtocol
    }
    // On failure the scan has already returned and released its real readback buffer.
    // No synthetic charge is retained for unknown private CI caches.
    let pixels = try result.get()
    try request.requireCurrent()
    return pixels
  }
  static func hash(_ data:Data)->String{SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
  /// Same original 64-row RGBAf scan, with explicit stricter active source-domain admission.
  static func validateOpaque(_ image:CIImage,context:CIContext,request:Request,input:Bool,
    observeOutputBandForTesting: ((OutputValidationBandObservation) -> Void)? = nil)throws->Int {
    let e=image.extent
    guard e.origin == .zero,e == e.integral,e.width>0,e.height>0,e.width<=16384,e.height<=16384 else{throw DevelopmentV3Error.invalidGraph}
    let width=Int(e.width),height=Int(e.height),reservation=try request.scope.reserveCPUFallback(bytes:width*64*16)
    defer{reservation.releaseAfterStorageReleased()}
    var count=0
    for y in stride(from:0,to:height,by:64) {
      try request.requireCurrent()
      let h=min(64,height-y)
      var nativeTaskStarted=false,nativeJoinedNS:UInt64?,validatedPixels=0
      do {
        // Defer runs after the readback/task pool exits, also on a validation error.
        // The original reservation stays charged until the whole scan returns.
        defer {
          if !input {
            let poolExitedNS=DispatchTime.now().uptimeNanoseconds
            context.clearCaches()
            let observation=OutputValidationBandObservation(requestID:request.id,
              bandIndex:y/64,firstRow:y,rows:h,validatedPixels:validatedPixels,
              nativeTaskStarted:nativeTaskStarted,nativeJoinedNS:nativeJoinedNS,
              poolExitedNS:poolExitedNS,clearReturnedNS:DispatchTime.now().uptimeNanoseconds)
            OutputValidationScalarSink.shared.emit(observation);observeOutputBandForTesting?(observation)
          }
        }
        try autoreleasepool {
          let rect=CGRect(x:0,y:y,width:width,height:h)
          var values=[Float](repeating:.nan,count:width*h*4)
          try values.withUnsafeMutableBytes{bytes in
            let target=CIRenderDestination(bitmapData:bytes.baseAddress!,width:width,height:h,bytesPerRow:width*16,format:.RGBAf)
            target.colorSpace=DevelopmentColorEngineV3.linearSRGB;target.alphaMode = .premultiplied
            target.isClamped=false;target.isDithered=false;target.isFlipped=true
            let task=try context.startTask(toRender:image,from:rect,to:target,at:.zero)
            if !input { nativeTaskStarted=true }
            do {
              _ = try task.waitUntilCompleted()
              if !input { nativeJoinedNS=DispatchTime.now().uptimeNanoseconds }
            } catch {
              let original=error
              if let _ = try? task.waitUntilCompleted(), !input {
                nativeJoinedNS=DispatchTime.now().uptimeNanoseconds
              }
              throw original
            }
          }
          for i in stride(from:0,to:values.count,by:4) {
            guard values[i].isFinite,values[i+1].isFinite,values[i+2].isFinite,values[i+3] == 1 else{throw DevelopmentError.invalidEncoding}
            if input {guard (0...1).contains(values[i]),(0...1).contains(values[i+1]),(0...1).contains(values[i+2]) else{throw DevelopmentError.invalidEncoding}}
          }
          count += width*h
          if !input { validatedPixels=width*h }
        }
      }
      try request.requireCurrent()
    }
    return count
  }
  static func apply(_ image:CIImage,parameters:DevelopmentAdjustmentsV3,capture:URL,context:CIContext,request:Request)throws->(CIImage,Observation) {
    try request.requireCurrent()
    _ = try BrilliancePlan(extent:image.extent) // Pure schedule/domain admission before any native task.
    let count=try validateInputWithOwnedContext(image,request:request)
    let scale=try BrillianceMapCPU.scale(width:Int(image.extent.width),height:Int(image.extent.height))
    let rowBytes=(scale.width*4+63) & ~63
    _ = try BrillianceMapCPU.layout(width:scale.width,height:scale.height,bytesPerRow:rowBytes,byteCount:rowBytes*scale.height)
    let ticket=try request.scope.reserveCPUFallback(bytes:rowBytes*scale.height+4096)
    defer{ticket.releaseAfterStorageReleased()}
    let generated=try autoreleasepool { ()throws->Data in
      var proxy=Data(count:rowBytes*scale.height)
      let space=DevelopmentColorEngineV3.linearSRGB
      let captureContext=CIContext(options:[.workingColorSpace:space,.outputColorSpace:space,.workingFormat:CIFormat.RGBAf.rawValue,
        .cacheIntermediates:false,.highQualityDownsample:false,.memoryTarget:512])
      defer{captureContext.clearCaches()}
      let canvas=CGRect(x:0,y:0,width:scale.width,height:scale.height),factor=CGFloat(scale.numerator)/CGFloat(scale.denominator)
      let sampled=image.clampedToExtent().samplingNearest().transformed(by:.init(scaleX:factor,y:factor),highQualityDownsample:true).cropped(to:canvas)
      try request.requireCurrent()
      try proxy.withUnsafeMutableBytes{bytes in
        let target=CIRenderDestination(bitmapData:bytes.baseAddress!,width:scale.width,height:scale.height,bytesPerRow:rowBytes,format:.BGRA8)
        target.colorSpace=space;target.alphaMode = .premultiplied;target.isClamped=true;target.isDithered=false;target.isFlipped=true
        let task=try captureContext.startTask(toRender:sampled,from:canvas,to:target,at:.zero)
        do{_ = try task.waitUntilCompleted()}catch{let original=error;_ = try?task.waitUntilCompleted();throw original}
      }
      try request.requireCurrent()
      return try BrillianceMapCPU.generate(proxy,width:scale.width,height:scale.height,bytesPerRow:rowBytes,check:request.requireCurrent).bytes
    }
    let mapTicket=try request.scope.reserveCPUFallback(bytes:4096)
    let rows:MapRows
    do { rows=try MapRows(generated,width:31,height:31,reservation:mapTicket) }
    catch {mapTicket.releaseAfterStorageReleased();throw error}
    var tiled:CGRect?
    let output=try PublicBrilliance.graph(image:image,provider:rows,local:0.5,shadow:0,observeTiledJoint:{tiled=$0})
    guard tiled == image.extent else{throw DevelopmentV3Error.invalidGraph}
    // The CI image provider retains rows itself; its immutable1922B is not a native CI cache.
    _ = try validateOpaque(output,context:context,request:request,input:false)
    try request.requireCurrent()
    let observation=Observation(requestID:request.id,version:version,transport:transportVersion,mapSHA256:hash(generated),
      sourceSHA256:try RenderFiles.hash(capture),prefixFingerprint:try EditingFingerprint.of(parameters),nativePixels:count)
    try request.requireCurrent()
    return(output,observation)
  }
}
