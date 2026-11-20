import Foundation
import CoreImage
import CoreVideo
import IOSurface
import Metal
import Darwin

/// Shared by proxy/producer/ready/display/retired. Physical aliases have ONE ticket.
final class ThumbnailLedger: @unchecked Sendable {
  enum Kind: Equatable { case summary, filters, proxy }
  enum Phase { case reserved, building, ready, display, retired }
  private struct Entry { var bytes,cpu,gpu:Int;let kind:Kind;var phase:Phase;var managed=false }
  private let lock=NSLock()
  private var entries:[UUID:Entry]=[:],peak=0
  private func limit(_ kind:Kind)->Int {
    switch kind { case .summary:return DevelopmentThumbnailBudgetV1.summaryBytes
    case .filters:return DevelopmentThumbnailBudgetV1.filterBytes
    case .proxy:return DevelopmentThumbnailBudgetV1.proxyBytes }
  }
  func reserve(_ bytes:Int,kind:Kind)throws->ThumbnailTicket {
    lock.lock();defer{lock.unlock()}
    guard bytes>0,bytes<=limit(kind),entries.values.reduce(0,{$0+$1.bytes})<=DevelopmentThumbnailBudgetV1.totalBytes-bytes,
      entries.values.filter({$0.kind==kind}).reduce(0,{$0+$1.bytes})<=limit(kind)-bytes else { throw DevelopmentThumbnailError.budgetUnavailable }
    let id=UUID();entries[id] = .init(bytes:bytes,cpu:0,gpu:0,kind:kind,phase:.reserved)
    peak=max(peak,entries.values.reduce(0,{$0+$1.bytes}));return ThumbnailTicket(id:id,ledger:self)
  }
  func adjust(_ id:UUID,bytes:Int,cpu:Int,gpu:Int)throws {
    lock.lock();defer{lock.unlock()}
    guard var value=entries[id],bytes>0,cpu>=0,gpu>=0 else { throw DevelopmentThumbnailError.invalidLease }
    // Even protocol-breaking allocation remains fully charged until physically released.
    value.bytes=bytes;value.cpu=cpu;value.gpu=gpu;value.phase = .building;entries[id]=value
    let total=entries.values.reduce(0,{$0+$1.bytes});peak=max(peak,total)
    guard total<=DevelopmentThumbnailBudgetV1.totalBytes,
      entries.values.filter({$0.kind==value.kind}).reduce(0,{$0+$1.bytes})<=limit(value.kind) else { throw DevelopmentThumbnailError.budgetUnavailable }
  }
  func phase(_ id:UUID,_ phase:Phase) { lock.lock();defer{lock.unlock()};entries[id]?.phase=phase }
  func managed(_ id:UUID){lock.lock();defer{lock.unlock()};entries[id]?.managed=true}
  func release(_ id:UUID) { lock.lock();defer{lock.unlock()};entries.removeValue(forKey:id) }
  func snapshot()->DevelopmentThumbnailStatistics {
    lock.lock();defer{lock.unlock()};var s=DevelopmentThumbnailStatistics()
    for e in entries.values {
      s.unionBytes+=e.bytes;s.cpuBytes+=e.cpu;s.gpuBytes+=e.gpu
      if e.managed{s.managedBackingBytes+=e.bytes;s.managedBackingCount+=1;if case .retired=e.phase{s.retiredManagedBackingBytes+=e.bytes}}
      switch e.phase { case .reserved:s.reservedBytes+=e.bytes
      case .building:s.inFlightBytes+=e.bytes
      case .retired:s.retiredBytes+=e.bytes
      default:break }
    };s.peakUnionBytes=peak;return s
  }
}
final class ThumbnailTicket: @unchecked Sendable {
  let id:UUID
  private let ledger:ThumbnailLedger
  private let lock=NSLock();private var released=false
  init(id:UUID,ledger:ThumbnailLedger){self.id=id;self.ledger=ledger}
  func adjust(bytes:Int,cpu:Int,gpu:Int)throws{try ledger.adjust(id,bytes:bytes,cpu:cpu,gpu:gpu)}
  func phase(_ phase:ThumbnailLedger.Phase){ledger.phase(id,phase)}
  func markManaged(){ledger.managed(id)}
  /// Storage owner must clear all views/storage BEFORE this call; idempotent under callback races.
  func release(){lock.lock();guard !released else{lock.unlock();return};released=true;lock.unlock();ledger.release(id)}
  deinit{release()}
}

/// A single IOSurface is CPU/CI/Metal storage, never a CPU copy plus a GPU upload.
final class ThumbnailSurface: @unchecked Sendable {
  let width,height,rowBytes,bytes:Int
  let deviceRegistryID:UInt64
  let ticket:ThumbnailTicket
  private let lock=NSLock()
  private var surface:IOSurface?
  private var texture:MTLTexture?
  private var buffer:CVPixelBuffer?
  private var reads=0,retired=false,producer=true,gpuJoined=false
  private var waiters:[CheckedContinuation<Void,Never>]=[]
  let float:Bool
  static func layout(width:Int,height:Int,float:Bool)throws->(Int,Int) {
    guard width>0,height>0,width<=256,height<=256 else{throw DevelopmentThumbnailError.invalidRequest}
    let row=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,width*(float ? 16:4)),page=Int(getpagesize())
    return(row,((row*height+page-1)/page)*page)
  }
  init(width:Int,height:Int,float:Bool,kind:ThumbnailLedger.Kind,ledger:ThumbnailLedger,device:MTLDevice,diagnostic:DevelopmentThumbnailDiagnostic.Callback? = nil)throws {
    diagnostic?(.init("summary.surface.layout.before",width:width,height:height))
    let layout=try Self.layout(width:width,height:height,float:float)
    diagnostic?(.init("summary.surface.layout.returned",width:width,height:height,rowBytes:layout.0,allocationBytes:layout.1))
    ticket=try ledger.reserve(layout.1,kind:kind);self.width=width;self.height=height;self.float=float
    rowBytes=layout.0;bytes=layout.1;deviceRegistryID=device.registryID
    var createdSurface:IOSurface?,createdTexture:MTLTexture?,createdBuffer:CVPixelBuffer?
    do {
      let props:[CFString:Any]=[kIOSurfaceWidth:width,kIOSurfaceHeight:height,kIOSurfaceBytesPerRow:layout.0,
        kIOSurfaceBytesPerElement:float ? 16:4,kIOSurfaceAllocSize:layout.1,
        kIOSurfacePixelFormat:float ? kCVPixelFormatType_128RGBAFloat:kCVPixelFormatType_32RGBA]
      guard let value=IOSurfaceCreate(props as CFDictionary)else{throw DevelopmentThumbnailError.budgetUnavailable}
      createdSurface=value
      let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:float ? .rgba32Float:.rgba8Unorm,width:width,height:height,mipmapped:false)
      desc.storageMode = .shared;desc.usage=[.shaderRead,.shaderWrite,.renderTarget]
      guard let t=device.makeTexture(descriptor:desc,iosurface:value,plane:0)else{throw DevelopmentThumbnailError.unavailableDevice}
      createdTexture=t
      // Texture and CV views alias this IOSurface allocation. Any real distinct copy is forbidden.
      let actual=max(IOSurfaceGetAllocSize(value),t.allocatedSize)
      try ticket.adjust(bytes:actual,cpu:actual,gpu:actual)
      diagnostic?(.init("summary.surface.actual-allocation",width:width,height:height,rowBytes:IOSurfaceGetBytesPerRow(value),allocationBytes:actual))
      guard actual==layout.1,IOSurfaceGetBytesPerRow(value)==layout.0,t.storageMode == .shared else{diagnostic?(.init("summary.surface.layout-mismatch",error:DevelopmentThumbnailError.invalidEncoding));throw DevelopmentThumbnailError.invalidEncoding}
      if float {
        var raw:Unmanaged<CVPixelBuffer>?
        let result=CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault,value,[kCVPixelBufferMetalCompatibilityKey:true]as CFDictionary,&raw)
        guard result==kCVReturnSuccess,let raw else{diagnostic?(.init("summary.surface.cv-create-failed",error:DevelopmentThumbnailError.invalidEncoding));throw DevelopmentThumbnailError.invalidEncoding}
        let cv=raw.takeRetainedValue()
        guard let backing=CVPixelBufferGetIOSurface(cv),IOSurfaceGetID(backing.takeUnretainedValue())==IOSurfaceGetID(value),
          CVPixelBufferGetWidth(cv)==width,CVPixelBufferGetHeight(cv)==height,CVPixelBufferGetBytesPerRow(cv)==layout.0,
          CVPixelBufferGetPixelFormatType(cv)==kCVPixelFormatType_128RGBAFloat else{diagnostic?(.init("summary.surface.cv-layout-mismatch",width:CVPixelBufferGetWidth(cv),height:CVPixelBufferGetHeight(cv),rowBytes:CVPixelBufferGetBytesPerRow(cv),error:DevelopmentThumbnailError.invalidEncoding));throw DevelopmentThumbnailError.invalidEncoding}
        createdBuffer=cv
      }
      surface=createdSurface;texture=createdTexture;buffer=createdBuffer
    }catch{
      createdBuffer=nil;createdTexture=nil;createdSurface=nil;ticket.release();throw error
    }
  }
  var allocation:DevelopmentThumbnailAllocation { .init(allocationID:ticket.id,residentCPUBytes:bytes,residentGPUBytes:bytes,unionBytes:bytes,bytesPerRow:rowBytes) }
  /// Worker-only producer. Actual task joins on success/error before allowing retirement.
  func fill(_ image:CIImage,context:CIContext,diagnostic:DevelopmentThumbnailDiagnostic.Callback? = nil)throws {
    lock.lock();let target=texture;let open = !retired && producer;lock.unlock()
    diagnostic?(.init("summary.fill.extent",extent:image.extent,width:width,height:height,rowBytes:rowBytes,allocationBytes:bytes))
    guard open,let target,image.extent == CGRect(x:0,y:0,width:width,height:height)else{diagnostic?(.init("summary.fill.encoding-guard",extent:image.extent,error:DevelopmentThumbnailError.invalidEncoding));throw DevelopmentThumbnailError.invalidEncoding}
    let destination=CIRenderDestination(mtlTexture:target,commandBuffer:nil)
    destination.colorSpace=float ? DevelopmentColorEngineV3.linearSRGB:PhotoRenderer.sRGB
    destination.alphaMode = .premultiplied;destination.isFlipped=true;destination.isClamped = !float;destination.isDithered=false
    var task:CIRenderTask?
    do{
      diagnostic?(.init("summary.fill.start.before",extent:image.extent))
      task=try context.startTask(toRender:image,to:destination)
      diagnostic?(.init("summary.fill.start.returned"))
      _ = try task!.waitUntilCompleted()
      diagnostic?(.init("summary.fill.wait.returned"))
    }
    catch{if let task{_ = try? task.waitUntilCompleted()};diagnostic?(.init("summary.fill.threw-after-join",error:error));throw error}
    lock.lock();gpuJoined=true;lock.unlock()
  }
  /// RAW thumbnail representation repair only, while unpublished producer exclusively owns
  /// this joined surface. No source-opacity assertion, canonical operator or validator change.
  /// Unlocking the CV shared view publishes CPU writes to its existing CI/Metal aliases.
  func normalizeRawProxyAlphaRoundoff()throws {
    lock.lock();var owned=buffer
    let valid = float && !retired && producer && gpuJoined && reads==0 && owned != nil
    if valid{reads+=1};lock.unlock()
    guard valid else{throw DevelopmentThumbnailError.invalidLease}
    var locked=false
    defer{
      if locked,let owned{CVPixelBufferUnlockBaseAddress(owned,[])}
      owned=nil;lock.lock();reads-=1;lock.unlock();releaseIfJoined()
    }
    guard owned != nil,CVPixelBufferLockBaseAddress(owned!,[])==kCVReturnSuccess else{throw DevelopmentThumbnailError.invalidLease}
    locked=true
    guard let pointer=CVPixelBufferGetBaseAddress(owned!)else{throw DevelopmentThumbnailError.invalidEncoding}
    try Self.normalizeRawProxyPixels(pointer,width:width,height:height,rowBytes:rowBytes)
    let status=CVPixelBufferUnlockBaseAddress(owned!,[]);locked=false
    guard status==kCVReturnSuccess else{throw DevelopmentThumbnailError.invalidEncoding}
  }
  /// Two passes: an invalid pixel anywhere prevents ALL mutation. The second pass writes
  /// only exact nextUp(1) alpha; every valid premultiplied lane, signed zero and padding bypass.
  static func normalizeRawProxyPixels(_ pointer:UnsafeMutableRawPointer,width:Int,height:Int,rowBytes:Int)throws {
    guard width>0,height>0,width<=256,height<=256,rowBytes>=width*16 else{throw DevelopmentThumbnailError.invalidEncoding}
    for y in 0..<height {
      let row=pointer.advanced(by:y*rowBytes).assumingMemoryBound(to:Float.self)
      for x in 0..<width {
        let n=x*4
        guard row[n].isFinite,row[n+1].isFinite,row[n+2].isFinite,row[n+3].isFinite,
          row[n+3]>=0,(row[n+3]<=1 || row[n+3].bitPattern==0x3f800001) else{throw DevelopmentThumbnailError.invalidEncoding}
      }
    }
    for y in 0..<height {
      let row=pointer.advanced(by:y*rowBytes).assumingMemoryBound(to:Float.self)
      for x in 0..<width {
        let n=x*4
        if row[n+3].bitPattern==0x3f800001 {
          let a=row[n+3];row[n]/=a;row[n+1]/=a;row[n+2]/=a;row[n+3]=1
        }
      }
    }
  }
  func finishProducer(){lock.lock();producer=false;lock.unlock();releaseIfJoined()}
  /// Scoped CPU access only; no Data/Float array copy and no pointer escapes.
  func withFloatPixels<T>(diagnostic:DevelopmentThumbnailDiagnostic.Callback? = nil,_ body:(UnsafeRawPointer,Int)throws->T)throws->T {
    lock.lock();var owned=buffer;let valid = !retired && gpuJoined;if valid{reads+=1};lock.unlock()
    guard valid else{throw DevelopmentThumbnailError.invalidLease}
    var locked=false
    defer{
      if locked,owned != nil{CVPixelBufferUnlockBaseAddress(owned!,.readOnly)}
      owned=nil // No remaining CV alias when the physical charge may be released.
      lock.lock();reads-=1;lock.unlock();releaseIfJoined()
    }
    diagnostic?(.init("summary.float-read.lock.before"))
    guard float,owned != nil,CVPixelBufferLockBaseAddress(owned!,.readOnly)==kCVReturnSuccess else{diagnostic?(.init("summary.float-read.lock-failed",error:DevelopmentThumbnailError.invalidLease));throw DevelopmentThumbnailError.invalidLease}
    diagnostic?(.init("summary.float-read.lock.returned"))
    locked=true;guard let p=CVPixelBufferGetBaseAddress(owned!)else{diagnostic?(.init("summary.float-read.no-base-address",error:DevelopmentThumbnailError.invalidEncoding));throw DevelopmentThumbnailError.invalidEncoding}
    return try body(UnsafeRawPointer(p),rowBytes)
  }
  /// Same worker, after actual producer join. No texture escapes or secondary readback pipeline.
  func withRGBA8Pixels<T>(_ body:(UnsafeRawPointer,Int)throws->T)throws->T {
    lock.lock();var owned=surface;let valid = !float && !retired && !producer && gpuJoined && owned != nil
    if valid{reads+=1};lock.unlock()
    guard valid else{throw DevelopmentThumbnailError.invalidLease}
    var locked=false
    defer{
      if locked,let value=owned{IOSurfaceUnlock(value,.readOnly,nil)}
      owned=nil;lock.lock();reads-=1;lock.unlock();releaseIfJoined()
    }
    guard let value=owned,IOSurfaceLock(value,.readOnly,nil)==0 else{throw DevelopmentThumbnailError.invalidEncoding}
    locked=true
    return try body(UnsafeRawPointer(IOSurfaceGetBaseAddress(value)),rowBytes)
  }
  /// The caller's graph/context views must drain before this resource retires.
  func withImage<T>(_ body:(CIImage)throws->T)throws->T {
    lock.lock();var owned=buffer;let valid = !retired && gpuJoined;if valid{reads+=1};lock.unlock()
    guard valid else{throw DevelopmentThumbnailError.invalidLease}
    defer{owned=nil;lock.lock();reads-=1;lock.unlock();releaseIfJoined()}
    guard float,owned != nil else{throw DevelopmentThumbnailError.invalidLease}
    return try autoreleasepool{try body(CIImage(cvPixelBuffer:owned!,options:[.colorSpace:DevelopmentColorEngineV3.linearSRGB]))}
  }
  func beginRead(commandBuffer:MTLCommandBuffer)throws->MTLTexture {
    lock.lock()
    guard !retired,!producer,let texture,commandBuffer.status == .notEnqueued,commandBuffer.commandQueue.device.registryID==deviceRegistryID else{lock.unlock();throw DevelopmentThumbnailError.invalidLease}
    reads+=1;lock.unlock()
    commandBuffer.addCompletedHandler{[self]_ in lock.lock();reads-=1;lock.unlock();releaseIfJoined()}
    return texture
  }
  func retire(){lock.lock();retired=true;ticket.phase(.retired);lock.unlock();releaseIfJoined()}
  func retireAndJoin()async {
    retire()
    await withCheckedContinuation{c in lock.lock();if surface==nil{lock.unlock();c.resume()}else{waiters.append(c);lock.unlock()}}
  }
  private func releaseIfJoined(){
    lock.lock()
    guard retired,!producer,reads==0,surface != nil else{lock.unlock();return}
    // Clear ALL aliasing views before dropping the physical charge. Released handles may survive.
    buffer=nil;texture=nil;surface=nil;let done=waiters;waiters=[];ticket.release();lock.unlock()
    for c in done{c.resume()}
  }
  deinit{precondition(reads==0,"thumbnail display read must join before owner release");buffer=nil;texture=nil;surface=nil;ticket.release()}
}

final class ThumbnailSetOwner: ThumbnailTextureReadOwner, ThumbnailPresentationReadOwner, @unchecked Sendable {
  let id=UUID(),token=UUID(),descriptor:DevelopmentThumbnailSetDescriptor
  private let lock=NSLock();private var surfaces:[ThumbnailSurface],managedBackings:[ThumbnailImageBacking],adopted=false,retired=false
  private let gate:ThumbnailDeliveryGate
  init(descriptor:DevelopmentThumbnailSetDescriptor,surfaces:[ThumbnailSurface],managedBackings:[ThumbnailImageBacking]=[],gate:ThumbnailDeliveryGate){self.descriptor=descriptor;self.surfaces=surfaces;self.managedBackings=managedBackings;self.gate=gate;for s in surfaces{s.ticket.phase(.ready)};for b in managedBackings{b.phase(.ready)}}
  func ready()->DevelopmentThumbnailReadyLease{.init(setID:id,descriptor:descriptor,ownershipToken:token)}
  func adopt()throws->DevelopmentThumbnailDisplayLease {
    try gate.whileOpen {
      lock.lock();defer{lock.unlock()};guard !adopted,!retired,descriptor.presentationMode == .texture else{throw DevelopmentThumbnailError.invalidLease}
      adopted=true;for s in surfaces{s.ticket.phase(.display)}
      return .init(setID:id,descriptor:descriptor,ownershipToken:token,reader:self)
    }
  }
  func adoptPresentation()throws->DevelopmentThumbnailPresentationLease {
    try gate.whileOpen {
      lock.lock();defer{lock.unlock()}
      guard !adopted,!retired,descriptor.presentationMode == .managedImage,managedBackings.count==descriptor.tiles.count else{throw DevelopmentThumbnailError.invalidLease}
      adopted=true;for b in managedBackings{b.phase(.display)}
      return .init(setID:id,descriptor:descriptor,tiles:managedBackings.map(\.descriptor),ownershipToken:token,reader:self)
    }
  }
  func cgImage(index:Int)throws->CGImage {
    try gate.whileOpen {
      lock.lock();defer{lock.unlock()}
      guard adopted,!retired,descriptor.presentationMode == .managedImage,managedBackings.indices.contains(index)else{throw DevelopmentThumbnailError.invalidLease}
      return try managedBackings[index].getImage()
    }
  }
  func encodeRead(index:Int,commandBuffer:MTLCommandBuffer,encode:(MTLTexture)->Void)throws {
    let texture=try gate.whileOpen{()->MTLTexture in
      lock.lock();guard adopted,!retired,surfaces.indices.contains(index)else{lock.unlock();throw DevelopmentThumbnailError.invalidLease}
      let surface=surfaces[index];lock.unlock();return try surface.beginRead(commandBuffer:commandBuffer)
    }
    // User encoding runs outside our ownership locks; its already-registered read retains storage.
    encode(texture)
  }
  func retireAndJoin()async {
    lock.lock();retired=true;let owned=surfaces,images=managedBackings;managedBackings=[];lock.unlock()
    for image in images{image.detach()}
    for s in owned{await s.retireAndJoin()}
    lock.lock();surfaces=[];lock.unlock()
  }
  func revokeReads(){gate.revoke();lock.lock();retired=true;for s in surfaces{s.ticket.phase(.retired)};for b in managedBackings{b.phase(.retired)};lock.unlock()}
  var isAdopted:Bool{lock.lock();defer{lock.unlock()};return adopted}
}
