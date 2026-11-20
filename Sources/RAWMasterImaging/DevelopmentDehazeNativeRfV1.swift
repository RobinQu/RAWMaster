import CoreImage
import Foundation
import RAWMasterCore

/// Operation-scoped ownership: public callers return joined pixels/artifacts, never a lazy
/// CIImage. Files outlive every graph/readback and are checked after the short pool drains.
final class DevelopmentDehazeNativeResources: @unchecked Sendable {
  @TaskLocal static var current:DevelopmentDehazeNativeResources?
  enum Phase:Equatable { case directoryCreated,scalarSubmitted,scalarJoined,providerReady }
  typealias Observer=(Phase,URL)throws->Void
  private var leases=[Lease]()
  private var contexts=[WeakContext]()
  let observer:Observer?
  init(observer:Observer?=nil){self.observer=observer}
  private final class WeakContext { weak var value:CIContext?;init(_ value:CIContext){self.value=value} }
  func register(_ context:CIContext){contexts.append(WeakContext(context))}
  func add(_ scratch:DehazeRfScratchV1)->Lease {let lease=Lease(scratch);leases.append(lease);return lease}
  func observe(_ phase:Phase,_ directory:URL)throws{try observer?(phase,directory)}
  private func clearCaches(){for context in contexts{context.value?.clearCaches()};contexts.removeAll()}
  func finish()throws{
    var failure:Error?
    for lease in leases {do{try lease.finish()}catch{failure=failure ?? error}}
    if let failure{throw failure};leases.removeAll()
  }
  static func run<T>(owner:DevelopmentDehazeNativeResources?=nil,_ operation:()throws->T)throws->T {
    if current != nil{return try operation()}
    let resources=owner ?? DevelopmentDehazeNativeResources()
    let outcome:Result<T,Error> = autoreleasepool {
      $current.withValue(resources) {
        defer{resources.clearCaches()}
        return Result{try operation()}
      }
    }
    // Even cancellation, malformed input and partially written files are checked here.
    // An export may already have durably published at this point. A cleanup error is
    // reported without deleting that output; callers retain ordinary recovery semantics.
    // A cleanup fault must never be silently converted into a successful frame/export.
    do{try resources.finish()}catch{
      if case .failure(let primary)=outcome{throw ExitFailure(primary:primary,cleanup:error)}
      throw error
    }
    return try outcome.get()
  }
  struct ExitFailure:Error {let primary:Error,cleanup:Error}
  /// Preserve capture revocation even when cleanup also failed. The thrown aggregate
  /// still retains both diagnostics; callers use this only to invalidate source leases.
  static func captureFault(_ error:Error)->PreviewCaptureFault? {
    if let fault=error as? PreviewCaptureFault{return fault}
    if let failure=error as? ExitFailure{return captureFault(failure.primary)}
    return nil
  }
  final class Lease {
    let scratch:DehazeRfScratchV1,state=DehazeRfStateV1()
    weak var provider:DehazeRfProviderV1?
    private let lock=NSLock()
    private var cleanup:Result<Void,Error>?
    init(_ scratch:DehazeRfScratchV1){self.scratch=scratch}
    /// Retained by the provider only as a late-release safety net. The outer owner
    /// still checks the recorded result; no successful public return relies on deinit.
    func providerReleased(){lock.lock();defer{lock.unlock()};if cleanup==nil{cleanup=Result{try scratch.finish()}}}
    func finish()throws{
      guard provider==nil else{throw PreviewPresentationError.allocationProtocol}
      if scratch.providerOpened{
        guard state.storageReleased else{throw PreviewPresentationError.allocationProtocol}
      }
      providerReleased()
      lock.lock();let result=cleanup;lock.unlock()
      try result?.get();try state.check()
    }
  }
}

/// Native Rf is a storage boundary, not a proxy: native dimensions, radius, F32
/// scalar values and all signed restore formulas are unchanged. The v1 guide already
/// lives in R; only positive v2 performs its original RGB dot before storage.
enum DevelopmentDehazeNativeRfV1 {
  static let version="dehaze-native-rf256-signed-v1-split-v2-v1"
  enum Kind {case signedV1,positiveV2}
  static func isActive(_ p:DevelopmentAdvancedDetailV3?)->Bool{
    guard let p else{return false};return p.dehaze.enabled && p.dehaze.amount != 0 && p.preparedDehaze != nil
  }
  static func keySuffix(_ p:DevelopmentAdvancedDetailV3?)->String{isActive(p) ? "/"+version:""}
  static func supports(width:Int,height:Int)->Bool{
    // Preserve the existing bounded row allocator. Wider or over-budget legal source
    // images use the original fused graph; there is no resize or new source rejection.
    guard width>0,width<=9504,height>0,height<=DevelopmentLocalEditLimits.maximumSourceDimension else{return false}
    let (pixels,a)=width.multipliedReportingOverflow(by:height)
    let (bytes,b)=pixels.multipliedReportingOverflow(by:4)
    return !a && !b && bytes>0 && bytes<=DehazeRfScratchV1.cap
  }
  static func apply(_ kind:Kind,to input:CIImage,airlight:DevelopmentDehazeAirlightV1,
    sourceSize:DevelopmentPixelSize,amount:Double,context:CIContext,
    checkCancellation:(()throws->Void)?=nil)throws->CIImage?{
    // Direct graph-construction clients may intentionally retain CIImage. Only owners
    // that enclose the final joined readback use files; this avoids an escaping lease.
    guard let resources=DevelopmentDehazeNativeResources.current,
      input.extent==CGRect(x:0,y:0,width:sourceSize.width,height:sourceSize.height),
      supports(width:sourceSize.width,height:sourceSize.height) else{return nil}
    if amount==0{return input}
    try Task.checkCancellation();try checkCancellation?()
    let scratch=try DehazeRfScratchV1(nativeWidth:sourceSize.width,height:sourceSize.height)
    let lease=resources.add(scratch)
    resources.register(context)
    try resources.observe(.directoryCreated,scratch.directory)
    let scope=PreviewPresentationScope();defer{scope.closeAndRetire()}
    var request=DevelopmentDehazeTIFFPreviewV1.Request(scope:scope,check:{try checkCancellation?()})
    request.observer={phase in
      switch phase {
      case .scalarSubmitted:try resources.observe(.scalarSubmitted,scratch.directory)
      case .scalarJoined:try resources.observe(.scalarJoined,scratch.directory)
      default:break
      }
    }
    // Retire completed prefix caches. The separate scalar producer is drained before
    // any restored output/geometry/FIT task can allocate its own graph intermediates.
    context.clearCaches()
    weak var producerWitness:CIContext?
    try autoreleasepool {
      let producer=CIContext(options:[.workingColorSpace:DevelopmentColorEngineV3.linearSRGB,
        .workingFormat:CIFormat.RGBAf.rawValue,.cacheIntermediates:false,.memoryTarget:512])
      producerWitness=producer;defer{producer.clearCaches()}
      let scalar:CIImage
      switch kind{
      case .signedV1:scalar=try DevelopmentDehazeEngineV3.darkGuide(input,airlight:airlight,sourceSize:sourceSize)
      case .positiveV2:
        let rgb=try DevelopmentDehazeColorGuideV2.guide(input,airlight:airlight,sourceSize:sourceSize)
        scalar=try DevelopmentDehazeRfTransportV1.scalar(rgb)
      }
      try DevelopmentDehazeRfTransportV1.file(scalar,scratch:scratch,context:producer,request:request)
    }
    guard producerWitness==nil else{throw PreviewPresentationError.allocationProtocol}
    try request.requireCurrent()
    let provider=try DehazeRfProviderV1(scratch,state:lease.state,onRelease:{lease.providerReleased()})
    lease.provider=provider
    let guide=provider.image()
    try resources.observe(.providerReady,scratch.directory)
    let restored:CIImage
    switch kind{
    case .signedV1:restored=try DevelopmentDehazeEngineV3.applyGuide(to:input,guide:guide,airlight:airlight,amount:amount)
    case .positiveV2:restored=try DevelopmentDehazeRfTransportV1.restoreNative(input,guide,airlight:airlight,amount:amount)
    }
    try lease.state.check();try request.requireCurrent();return restored
  }
}
