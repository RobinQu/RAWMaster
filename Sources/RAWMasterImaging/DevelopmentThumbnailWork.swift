import Foundation
import CoreImage
import Metal
import RAWMasterCore

final class ThumbnailDeliveryGate: @unchecked Sendable {
  private let lock=NSLock();private var open=true
  func revoke(){lock.lock();open=false;lock.unlock()}
  func whileOpen<T>(_ body:()throws->T)throws->T{lock.lock();defer{lock.unlock()};guard open else{throw DevelopmentThumbnailError.cancelled};return try body()}
  var isOpen:Bool{lock.lock();defer{lock.unlock()};return open}
}
final class ThumbnailBatch: @unchecked Sendable {
  let request:DevelopmentThumbnailRequest,key:String,source:DevelopmentLocalEditSourceBinding
  let gate:ThumbnailDeliveryGate
  let progress:@Sendable(DevelopmentThumbnailProgress)->Void
  var continuation:CheckedContinuation<DevelopmentThumbnailReadyLease,Error>?
  var scalars:DevelopmentAnalysisScalars?
  var surfaces:[ThumbnailSurface]=[],tiles:[DevelopmentThumbnailTileDescriptor]=[],candidateEV:[Float]=[]
  var managedBackings:[ThumbnailImageBacking]=[]
  init(request:DevelopmentThumbnailRequest,key:String,source:DevelopmentLocalEditSourceBinding,
       progress:@escaping @Sendable(DevelopmentThumbnailProgress)->Void,continuation:CheckedContinuation<DevelopmentThumbnailReadyLease,Error>,gate:ThumbnailDeliveryGate){
    self.request=request;self.key=key;self.source=source;self.progress=progress;self.continuation=continuation;self.gate=gate
  }
  func revoke(_ error:Error){gate.revoke();let c=continuation;continuation=nil;c?.resume(throwing:error)}
  func retireTiles(){for s in surfaces{s.retire()};for b in managedBackings{b.detach()};surfaces=[];managedBackings=[];tiles=[];candidateEV=[]}
}
enum ThumbnailStepResult: @unchecked Sendable {
  case proxy(ThumbnailProxy)
  case scalars(DevelopmentAnalysisScalars)
  case tile(ThumbnailSurface,DevelopmentThumbnailTileDescriptor,Float)
  case managedTile(ThumbnailImageBacking,DevelopmentThumbnailTileDescriptor,Float)
}
final class ThumbnailSettledHook: @unchecked Sendable {
  private let lock=NSLock()
  let batch:ThumbnailBatch
  private var value:ThumbnailProxy?
  private var failure:Error?
  private let native:PreviewNativeSource,ledger:ThumbnailLedger,device:MTLDevice
  private let contextOwner:ThumbnailWorkerContextV1?
  private let input: ThumbnailProxyInput
  init(batch: ThumbnailBatch, native: PreviewNativeSource, ledger: ThumbnailLedger,
       device: MTLDevice, contextOwner: ThumbnailWorkerContextV1? = nil) throws {
    // Validation belongs outside the native render callback's already deep stack.
    let recipe = try DevelopmentThumbnailEngine.proxyPreparationRecipe(batch.request)
    input = try native.thumbnailProxyInput(recipe: recipe, source: batch.source,
                                           generation: batch.request.preview.sourceGeneration)
    self.batch = batch; self.native = native; self.ledger = ledger
    self.device = device; self.contextOwner = contextOwner
  }
  func consume(_ image: CIImage) throws {
    guard batch.gate.isOpen else { return }
    do {
      let proxy = try native.prepareSettledThumbnailProxy(input: input, image: image, ledger: ledger,
        device: device, contextOwner: contextOwner, interest: { self.batch.gate.isOpen })
      lock.lock();if value==nil{value=proxy;lock.unlock()}else{lock.unlock();proxy.surface.retire()}
    }catch{lock.lock();if failure==nil{failure=error};lock.unlock()}
  }
  func takeFailure()->Error?{lock.lock();defer{lock.unlock()};let error=failure;failure=nil;return error}
  func take()->ThumbnailProxy?{lock.lock();defer{lock.unlock()};let p=value;value=nil;return p}
}
