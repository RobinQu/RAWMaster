import Foundation
import AppKit
import CoreImage
import CoreVideo
import IOSurface
import Metal
import Darwin

struct PreviewInteractiveLayout:Equatable {
  let width,height,rowBytes,bytes:Int
  let float:Bool
  static func make(width:Int,height:Int,float:Bool)throws->Self {
    guard width>0,height>0,width<=2400,height<=2400 else{throw PreviewPresentationError.invalidLayout}
    let row=IOSurfaceAlignProperty(kIOSurfaceBytesPerRow,width*(float ? 16:4))
    let page=Int(getpagesize()),bytes=((row*height+page-1)/page)*page
    return .init(width:width,height:height,rowBytes:row,bytes:bytes,float:float)
  }
}
/// Explicit IOSurface/CV/Metal views alias one physical ticket. No native-sized float buffer.
final class PreviewInteractiveProxyStorage {
  let layout:PreviewInteractiveLayout
  let ticket:PreviewPresentationReservation
  private var surface:IOSurface?,texture:MTLTexture?,buffer:CVPixelBuffer?
  private var joined=false
  let qaMainOwnerStore:PreviewQAMainPresentationWitness.Store?
  var qaIPTiming:PreviewQALifecycleTrace.IPTiming?
  var qaIPPurpose:PreviewQALifecycleTrace.IPPurpose = .fitCheck
  init(layout:PreviewInteractiveLayout,ticket:PreviewPresentationReservation,device:MTLDevice,qaMainOwnerStoreForTesting:PreviewQAMainPresentationWitness.Store?=nil)throws {
    self.layout=layout;self.ticket=ticket
    qaMainOwnerStore=PreviewQAMainPresentationWitness.resolvedStore(qaMainOwnerStoreForTesting)
    guard device.hasUnifiedMemory else{throw PreviewPresentationError.unsupported}
    var s:IOSurface?,t:MTLTexture?,cv:CVPixelBuffer?
    do {
      try ticket.requireOpenAdmission()
      let pixel=layout.float ? kCVPixelFormatType_128RGBAFloat:kCVPixelFormatType_32BGRA
      let properties:[CFString:Any]=[kIOSurfaceWidth:layout.width,kIOSurfaceHeight:layout.height,kIOSurfaceBytesPerRow:layout.rowBytes,kIOSurfaceBytesPerElement:layout.float ? 16:4,kIOSurfaceAllocSize:layout.bytes,kIOSurfacePixelFormat:pixel]
      guard let made=IOSurfaceCreate(properties as CFDictionary)else{throw PreviewPresentationError.displayCapacity};s=made
      let d=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:layout.float ? .rgba32Float:.bgra8Unorm,width:layout.width,height:layout.height,mipmapped:false)
      d.storageMode = .shared;d.usage=[.shaderRead,.shaderWrite,.renderTarget]
      guard let madeTexture=device.makeTexture(descriptor:d,iosurface:made,plane:0)else{throw PreviewPresentationError.unsupported};t=madeTexture
      let actual=max(IOSurfaceGetAllocSize(made),madeTexture.allocatedSize)
      try ticket.registerActualAllocation(bytes:actual)
      guard actual==layout.bytes,IOSurfaceGetBytesPerRow(made)==layout.rowBytes,IOSurfaceGetWidth(made)==layout.width,IOSurfaceGetHeight(made)==layout.height else{throw PreviewPresentationError.allocationProtocol}
      if layout.float {
        var raw:Unmanaged<CVPixelBuffer>?
        guard CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault,made,[kCVPixelBufferMetalCompatibilityKey:true]as CFDictionary,&raw)==kCVReturnSuccess,let raw else{throw PreviewPresentationError.allocationProtocol}
        let value=raw.takeRetainedValue();cv=value
        guard let actualSurface=CVPixelBufferGetIOSurface(value),IOSurfaceGetID(actualSurface.takeUnretainedValue())==IOSurfaceGetID(made),CVPixelBufferGetBytesPerRow(value)==layout.rowBytes,CVPixelBufferGetWidth(value)==layout.width,CVPixelBufferGetHeight(value)==layout.height,CVPixelBufferGetPixelFormatType(value)==kCVPixelFormatType_128RGBAFloat else{throw PreviewPresentationError.allocationProtocol}
      }
      surface=s;texture=t;buffer=cv
    }catch{cv=nil;t=nil;s=nil;ticket.releaseAfterStorageReleased();throw error}
  }
  func fill(_ image:CIImage,context:CIContext,check:()throws->Void)throws {
    try check();try ticket.requireOpenAdmission()
    guard let texture,image.extent==CGRect(x:0,y:0,width:layout.width,height:layout.height)else{throw PreviewPresentationError.invalidLayout}
    let destination=CIRenderDestination(mtlTexture:texture,commandBuffer:nil)
    destination.colorSpace=layout.float ? DevelopmentColorEngineV3.linearSRGB:PhotoRenderer.sRGB
    destination.alphaMode = .premultiplied;destination.isFlipped=true;destination.isClamped = !layout.float;destination.isDithered=false
    // Only the reused 1px F32 maximum readback needs a sentinel. Do not add a
    // full-proxy CPU pass or change the mask/reduction or output pixel math.
    joined=false
    let checkedPixel=layout.float && layout.width==1 && layout.height==1
    if checkedPixel{try withCheckedPixelAddress(readOnly:false){Self.poisonCheckedPixel($0)}}
    let qa=qaIPTiming;qaIPTiming=nil // Never retain a diagnostic collector in a displayed storage owner.
    let qaPurpose=qaIPPurpose
    let callBegan=qa.map{_ in PreviewQALifecycleTrace.IPTiming.now()}
    var waitBegan:UInt64?
    var qaRecorded=false
    var task:CIRenderTask?
    do{
      task=try context.startTask(toRender:image,to:destination)
      if let qa,let callBegan {
        waitBegan=PreviewQALifecycleTrace.IPTiming.now()
        let info:CIRenderInfo? = try task!.waitUntilCompleted()
        qa.task(qaPurpose,callBegan:callBegan,waitBegan:waitBegan,info:info,successful:true)
        qaRecorded=true // A later original 1px readback failure is not a second GPU task.
      } else {
        _ = try task!.waitUntilCompleted() // OFF retains the original immediate-discard lifetime.
      }
      if checkedPixel{try withCheckedPixelAddress(readOnly:true){_ = try Self.readCheckedPixel(UnsafeRawPointer($0))}}
      joined=true
    }catch{if let task{_ = try? task.waitUntilCompleted()}
      if !qaRecorded,let qa,let callBegan{qa.task(qaPurpose,callBegan:callBegan,waitBegan:waitBegan,info:nil,successful:false)}
      throw error}
    try check()
  }
  // Shared by the actual joined readback and pure malformed-write regressions.
  // Poison every channel on EVERY submission: an old successful zero is unsafe.
  static func poisonCheckedPixel(_ address:UnsafeMutableRawPointer){
    address.storeBytes(of:SIMD4<Float>(repeating:.nan),as:SIMD4<Float>.self)
  }
  static func readCheckedPixel(_ address:UnsafeRawPointer)throws->SIMD4<Float>{
    let value=address.loadUnaligned(as:SIMD4<Float>.self)
    guard value.x.isFinite,value.y.isFinite,value.z.isFinite,value.w.isFinite else{throw DevelopmentError.invalidEncoding}
    return value
  }
  private func withCheckedPixelAddress(readOnly:Bool,_ body:(UnsafeMutableRawPointer)throws->Void)throws{
    guard layout.float,layout.width==1,layout.height==1,let buffer else{throw PreviewPresentationError.invalidLayout}
    let flags:CVPixelBufferLockFlags=readOnly ? .readOnly:[]
    guard CVPixelBufferLockBaseAddress(buffer,flags)==kCVReturnSuccess else{throw PreviewPresentationError.cpuLockFailed}
    defer{CVPixelBufferUnlockBaseAddress(buffer,flags)}
    guard let address=CVPixelBufferGetBaseAddress(buffer),let surface,address==IOSurfaceGetBaseAddress(surface)else{throw PreviewPresentationError.invalidLayout}
    try body(address)
  }
  func withImage(_ body:(CIImage)throws->PreviewPixels)throws->PreviewPixels {
    guard layout.float,joined,let buffer else{throw PreviewPresentationError.allocationProtocol}
    return try autoreleasepool{try body(CIImage(cvPixelBuffer:buffer,options:[.colorSpace:DevelopmentColorEngineV3.linearSRGB]))}
  }
  func withPixels<T>(_ body:(UnsafeRawPointer,Int)throws->T)throws->T {
    guard layout.float,joined,let buffer,CVPixelBufferLockBaseAddress(buffer,.readOnly)==kCVReturnSuccess else{throw PreviewPresentationError.cpuLockFailed}
    defer{CVPixelBufferUnlockBaseAddress(buffer,.readOnly)}
    guard let address=CVPixelBufferGetBaseAddress(buffer),let surface,address==IOSurfaceGetBaseAddress(surface) else{throw PreviewPresentationError.invalidLayout}
    return try body(UnsafeRawPointer(address),layout.rowBytes)
  }
  func validateAllRGBA()throws {
    try withPixels{address,row in
      for y in 0..<layout.height{for x in 0..<layout.width{
        let p=address.loadUnaligned(fromByteOffset:y*row+x*16,as:SIMD4<Float>.self)
        guard p.x.isFinite,p.y.isFinite,p.z.isFinite,p.w.isFinite,(0...1).contains(p.w)else{throw DevelopmentError.invalidEncoding}
      }}
    }
  }
  func markRetired(){ticket.markRetired()}
  fileprivate func lockOutput()throws->IOSurface {
    guard !layout.float,joined,let surface else{throw PreviewPresentationError.allocationProtocol}
    var seed:UInt32=0
    guard IOSurfaceLock(surface,.readOnly,&seed)==kIOReturnSuccess else{throw PreviewPresentationError.cpuLockFailed}
    return surface
  }
  deinit{
    buffer=nil;texture=nil;surface=nil;ticket.releaseAfterStorageReleased()
    if !layout.float {
      PreviewQAMainPresentationWitness.managedStorageReleased(store:qaMainOwnerStore,ticketID:ticket.id,bytes:layout.bytes)
    }
  }
}

/// The CGDataProvider retains this backing; an NSImage may outlive its Service/scope.
final class PreviewInteractiveOutputStorage:PreviewSharedImageBacking {
  let storage:PreviewInteractiveProxyStorage
  let sharedImageLayout:PreviewSharedSurfaceLayout
  private let lock=NSLock()
  private var lockedSurface:IOSurface?
  private var released=false
  init(storage:PreviewInteractiveProxyStorage)throws {
    guard !storage.layout.float else{throw PreviewPresentationError.invalidLayout}
    self.storage=storage
    let l=storage.layout;sharedImageLayout = .init(width:l.width,height:l.height,rowBytes:l.rowBytes,allocationBytes:l.bytes)
  }
  var sharedImageBaseAddress:UnsafeRawPointer{UnsafeRawPointer(IOSurfaceGetBaseAddress(lockedSurface!))}
  func image(_ graph:CIImage,context:CIContext,check:()throws->Void)throws->NSImage {
    try storage.fill(graph,context:context,check:check)
    lockedSurface=try storage.lockOutput()
    do {
      let cg=try PreviewSharedImageBridge.makeCGImage(backing:self)
      let result=NSImage(cgImage:cg,size:CGSize(width:sharedImageLayout.width,height:sharedImageLayout.height))
      try check();return result
    }catch{sharedImageProviderDidRelease();throw error}
  }
  func sharedImageProviderDidRelease(){
    lock.lock();guard !released else{lock.unlock();return};released=true
    var status:Int32?
    if let surface=lockedSurface{var seed:UInt32=0;let actual=IOSurfaceUnlock(surface,.readOnly,&seed);status=actual;if actual != kIOReturnSuccess{storage.ticket.recordCleanupFailure()}}
    lockedSurface=nil
    lock.unlock()
    // This is unlock completion inside the CG callback, not callback return or storage release.
    PreviewQAMainPresentationWitness.managedUnlocked(store:storage.qaMainOwnerStore,ticketID:storage.ticket.id,
      bytes:storage.layout.bytes,attempted:status != nil,status:status)
    // Storage/ticket is released by the last backing owner, never by publication admission.
  }
  deinit{sharedImageProviderDidRelease()}
}

/// Reserved before native work. It uses the same global CPU/GPU union, not a second allowance.
final class PreviewInteractiveManagedOutput {
  let layout:PreviewInteractiveLayout
  let ticket:PreviewPresentationReservation
  let device:MTLDevice
  private let qaMainOwnerStoreForTesting:PreviewQAMainPresentationWitness.Store?
  private let lock=NSLock();private var consumed=false
  var qaIPTiming:PreviewQALifecycleTrace.IPTiming?
  init(layout:PreviewInteractiveLayout,ticket:PreviewPresentationReservation,device:MTLDevice,qaMainOwnerStoreForTesting:PreviewQAMainPresentationWitness.Store?=nil){self.layout=layout;self.ticket=ticket;self.device=device;self.qaMainOwnerStoreForTesting=qaMainOwnerStoreForTesting}
  func materialize(_ image:CIImage,context:CIContext,nativeSize:CGSize,approximation:PreviewApproximationInfo?=nil,fallback:String?=nil,storageObserverForTesting:((PreviewInteractiveProxyStorage)->Void)?=nil,check:()throws->Void)throws->PreviewPixels {
    lock.lock();let allowed = !consumed;consumed=true;lock.unlock()
    guard allowed else{throw PreviewPresentationError.allocationProtocol}
    guard image.extent==CGRect(x:0,y:0,width:layout.width,height:layout.height)else{throw PreviewPresentationError.invalidLayout}
    let qa=qaIPTiming;qaIPTiming=nil
    let surface=try PreviewInteractiveProxyStorage(layout:layout,ticket:ticket,device:device,qaMainOwnerStoreForTesting:qaMainOwnerStoreForTesting)
    storageObserverForTesting?(surface) // Synchronous, never stored; product callers pass nil.
    surface.qaIPTiming=qa;surface.qaIPPurpose = .output
    let backing=try PreviewInteractiveOutputStorage(storage:surface)
    let result=try backing.image(image,context:context,check:check)
    PreviewQAMainPresentationWitness.register(image:result,ticketID:ticket.id,bytes:layout.bytes,testingStore:qaMainOwnerStoreForTesting)
    return .init(image:result,nativeSize:nativeSize,outputSize:CGSize(width:layout.width,height:layout.height),bytes:layout.bytes,approximation:approximation,interactiveCanonicalFallbackReason:fallback,presentationTicket:ticket)
  }
}
