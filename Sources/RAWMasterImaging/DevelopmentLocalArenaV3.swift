import Foundation
import CoreImage
import Metal
import Darwin
import RAWMasterCore

/// Byte ownership only, never a pixel cache or executor. Charges survive cancellation and CI views
/// until the final buffer/deallocator releases the actual storage; no actor wait in deinit.
final class DevelopmentLocalChargeV3 {
  enum Kind { case metadata, analysis }
  private static let lock = NSLock()
  private static var metadata = 0, analysis = 0
  let kind: Kind
  private(set) var bytes: Int
  private var registered = false
  private var refundOnRelease = true
  init(_ bytes: Int, kind: Kind) throws {
    guard bytes > 0 else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    self.kind = kind; self.bytes = bytes
    Self.lock.lock(); defer { Self.lock.unlock() }
    let used = kind == .metadata ? Self.metadata:Self.analysis
    let limit = kind == .metadata ? DevelopmentLocalWorkEstimatorV1.metadataUnionBytes:DevelopmentLocalWorkEstimatorV1.analysisUnionBytes
    guard bytes <= limit-used, bytes <= DevelopmentLocalWorkEstimatorV1.combinedUnionBytes-Self.metadata-Self.analysis else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    if kind == .metadata { Self.metadata += bytes } else { Self.analysis += bytes }
    registered = true
  }
  deinit {
    guard registered,refundOnRelease else { return }
    Self.lock.lock(); defer { Self.lock.unlock() }
    if kind == .metadata { Self.metadata -= bytes } else { Self.analysis -= bytes }
  }
  /// A failed native release must not make still-owned pages available to another allocation.
  fileprivate func preserveDebitAfterFailedRelease() {
    Self.lock.lock();defer { Self.lock.unlock() };refundOnRelease=false
  }
  static func snapshot() -> (metadata: Int,analysis: Int) {
    lock.lock(); defer { lock.unlock() }; return (metadata,analysis)
  }
}
final class DevelopmentLocalAllocationV3 {
  let pointer: UnsafeMutableRawPointer
  let bytes: Int
  private let charge: DevelopmentLocalChargeV3
  private let testRelease: ((Int32,Int)->Void)?
  static func mappedLength(bytes: Int,pageSize: Int) throws -> Int {
    guard bytes > 0,pageSize > 0 else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let remainder=bytes%pageSize
    if remainder == 0 { return bytes }
    let (length,overflow)=bytes.addingReportingOverflow(pageSize-remainder)
    guard !overflow,length >= bytes,length > 0 else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    return length
  }
  init(bytes: Int, kind: DevelopmentLocalChargeV3.Kind,
       testStage: ((String,Int,Int,Int?)->Void)? = nil,
       testRelease: ((Int32,Int)->Void)? = nil) throws {
    let reserved=try Self.mappedLength(bytes:bytes,pageSize:Int(getpagesize()))
    testStage?("charge-before",bytes,reserved,nil)
    let charge:DevelopmentLocalChargeV3
    do { charge = try DevelopmentLocalChargeV3(reserved,kind:kind);testStage?("charge-after",bytes,reserved,nil) }
    catch { testStage?("charge-threw",bytes,reserved,nil);throw error }
    testStage?("mmap-before",bytes,reserved,nil)
    let mapped=mmap(nil,reserved,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0)
    guard mapped != MAP_FAILED else {
      testStage?("mmap-failed",bytes,reserved,nil);withExtendedLifetime(charge) {}
      throw DevelopmentPreviewError.memoryBudgetExceeded
    }
    guard let p=mapped else {
      // An address-zero mapping cannot be represented by our nonoptional pointer ABI.
      if munmap(mapped,reserved) != 0 { charge.preserveDebitAfterFailedRelease() }
      testStage?("mmap-unrepresentable",bytes,reserved,nil);withExtendedLifetime(charge) {}
      throw DevelopmentPreviewError.memoryBudgetExceeded
    }
    testStage?("mmap-returned",bytes,reserved,nil)
    pointer = p; self.bytes = reserved; self.charge = charge;self.testRelease=testRelease
    memset(p,0,reserved)
    // The legacy callback's fourth field is actualMallocBytes; never mislabel a mapping as malloc.
    testStage?("initialized",bytes,reserved,nil)
  }
  deinit {
    let status=munmap(pointer,bytes)
    if status != 0 { charge.preserveDebitAfterFailedRelease() }
    testRelease?(status,bytes)
    withExtendedLifetime(charge) {} // refund follows actual unmap and the scalar release observation
  }
}
/// The CI texture view retains the shared MTLBuffer. Its deallocator captures allocation/charge;
/// retaining an image or any native texture view therefore cannot prematurely return the bytes.
struct DevelopmentLocalTableV3 {
  let image: CIImage
  let width, height: Int
  let buffer: MTLBuffer
  let texture: MTLTexture
  init(texels: Int, fill: (UnsafeMutablePointer<SIMD4<Float>>) throws -> Void) throws {
    guard texels > 0, texels <= 4*1024*1024, let device = MTLCreateSystemDefaultDevice() else { throw DevelopmentV3Error.invalidGraph }
    width = min(4096,texels); height = (texels+width-1)/width
    let alignment = max(256,device.minimumLinearTextureAlignment(for:.rgba32Float))
    let row = ((width*16+alignment-1)/alignment)*alignment, page = Int(getpagesize())
    let length = ((row*height+page-1)/page)*page
    // bytesNoCopy requires page alignment and page-multiple length. Charge actual exposed resource
    // allocation before it can escape; padding belongs to the metadata union too.
    let charge = try DevelopmentLocalChargeV3(length,kind:.metadata)
    var address: UnsafeMutableRawPointer?
    guard posix_memalign(&address,page,length) == 0, let address else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    memset(address,0,length)
    guard let b = device.makeBuffer(bytesNoCopy:address,length:length,options:.storageModeShared,deallocator:{ p,_ in free(p); withExtendedLifetime(charge) {} }) else {
      free(address); throw DevelopmentPreviewError.memoryBudgetExceeded
    }
    guard b.allocatedSize <= length else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba32Float,width:width,height:height,mipmapped:false)
    descriptor.storageMode = .shared; descriptor.usage = .shaderRead
    guard let texture = b.makeTexture(descriptor:descriptor,offset:0,bytesPerRow:row) else { throw DevelopmentV3Error.invalidGraph }
    // Packing uses row stride, including buffer-texture row padding.
    if row == width*16 { try fill(b.contents().assumingMemoryBound(to:SIMD4<Float>.self)) }
    else {
      let temp = try DevelopmentLocalAllocationV3(bytes:texels*16,kind:.metadata)
      try fill(temp.pointer.assumingMemoryBound(to:SIMD4<Float>.self))
      for y in 0..<height { memcpy(b.contents().advanced(by:y*row),temp.pointer.advanced(by:y*width*16),min(width,texels-y*width)*16) }
    }
    guard let image = CIImage(mtlTexture:texture,options:[.colorSpace:NSNull()]) else { throw DevelopmentV3Error.invalidGraph }
    self.buffer = b; self.texture = texture; self.image = image
  }
}
