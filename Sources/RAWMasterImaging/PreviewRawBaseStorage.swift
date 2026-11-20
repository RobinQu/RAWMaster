import Foundation
import CoreImage
import CoreVideo
import IOSurface
import Darwin

enum RawBaseFillMode: Sendable { case whole, nativeStrips256 }

/// One explicit F32 allocation shared by CV/CoreImage views. Never a display image.
final class RawBaseStorage {
  let ownerIncarnation = UUID()
  private(set) var pointwiseInputCertificate: PreviewNativePointwiseCertificateV1.Input?
  var pointwiseSamplerCertificate: PreviewNativePointwiseCertificateV1.Sampler?
  let surface: IOSurface
  let pixelBuffer: CVPixelBuffer
  let width: Int, height: Int, rowBytes: Int, allocationBytes: Int
  static func layout(width: Int, height: Int) throws -> (rowBytes: Int, bytes: Int) {
    guard width > 0, height > 0 else { throw DevelopmentPreviewError.invalidRequest }
    let (row, overflow) = width.multipliedReportingOverflow(by: 16)
    guard !overflow else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let aligned = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, row)
    let (size, sizeOverflow) = aligned.multipliedReportingOverflow(by: height)
    guard !sizeOverflow, size > 0 else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    let page = Int(getpagesize())
    guard size <= Int.max - page else { throw DevelopmentPreviewError.memoryBudgetExceeded }
    return (aligned, ((size + page - 1) / page) * page)
  }
  init(width: Int, height: Int) throws {
    let layout = try Self.layout(width: width, height: height)
    let properties: [CFString: Any] = [kIOSurfaceWidth:width, kIOSurfaceHeight:height,
      kIOSurfaceBytesPerRow:layout.rowBytes, kIOSurfaceBytesPerElement:16,
      kIOSurfaceAllocSize:layout.bytes, kIOSurfacePixelFormat:kCVPixelFormatType_128RGBAFloat]
    guard let surface = IOSurfaceCreate(properties as CFDictionary) else { throw RawBaseCacheError.unavailable }
    self.surface = surface; self.width = width; self.height = height
    allocationBytes = IOSurfaceGetAllocSize(surface); rowBytes = IOSurfaceGetBytesPerRow(surface)
    var value: Unmanaged<CVPixelBuffer>?
    let status = CVPixelBufferCreateWithIOSurface(kCFAllocatorDefault, surface,
      [kCVPixelBufferMetalCompatibilityKey:true] as CFDictionary, &value)
    guard status == kCVReturnSuccess, let created = value else { value?.release(); throw RawBaseCacheError.unavailable }
    let buffer = created.takeRetainedValue()
    guard let backing = CVPixelBufferGetIOSurface(buffer),
      IOSurfaceGetID(backing.takeUnretainedValue()) == IOSurfaceGetID(surface),
      CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_128RGBAFloat,
      CVPixelBufferGetWidth(buffer) == width, CVPixelBufferGetHeight(buffer) == height,
      CVPixelBufferGetBytesPerRow(buffer) == rowBytes, rowBytes >= width * 16 else { throw RawBaseCacheError.unavailable }
    pixelBuffer = buffer
  }
  func image() -> CIImage {
    CIImage(cvPixelBuffer: pixelBuffer, options: [.colorSpace:DevelopmentColorEngineV2.linearSRGB])
  }
  /// The async render task MUST join before CPU access, even when caller cancellation is set.
  func fill(_ image: CIImage, context: CIContext, mode: RawBaseFillMode = .whole, checkpoint: (String) throws -> Void = { _ in }, pointwiseAuthority: String? = nil) throws {
    guard image.extent == CGRect(x:0,y:0,width:width,height:height) else { throw DevelopmentError.invalidGeometry }
    invalidatePointwiseCertificate()
    if pointwiseAuthority != nil { try poisonPointwiseInput() }
    let destination = CIRenderDestination(pixelBuffer: pixelBuffer)
    destination.colorSpace = DevelopmentColorEngineV2.linearSRGB
    destination.alphaMode = .premultiplied; destination.isClamped = false
    destination.isDithered = false
    // CV-backed CIImage consumes top-row-first storage. Keep logical CI coordinates unchanged;
    // destination flipped=true stores the logical upper row at the shared buffer base address.
    destination.isFlipped = true
    switch mode {
    case .whole:
      try checkpoint("before-base-native-fill")
      let task = try context.startTask(toRender: image, to: destination)
      _ = try task.waitUntilCompleted()
      try checkpoint("base-native-fill-joined")
    case .nativeStrips256:
      // Same global RAW image/full destination, no explicit upstream ROI/halo override.
      // Internal CI evaluation may differ; native bitwise equality is a required gate.
      for y in stride(from:0,to:height,by:256) {
        let rows = min(256,height-y), rect = CGRect(x:0,y:y,width:width,height:rows)
        try checkpoint("before-native-strip-\(y)-\(rows)")
        let task = try context.startTask(toRender:image,from:rect,to:destination,at:rect.origin)
        _ = try task.waitUntilCompleted()
        try checkpoint("native-strip-\(y)-\(rows)-joined")
      }
    }
    if let pointwiseAuthority {
      pointwiseInputCertificate = try scanPointwiseInput(authority:pointwiseAuthority)
    } else { try validateFinite() }
    try checkpoint("base-CPU-finite-complete")
  }
  func invalidatePointwiseCertificate() { pointwiseInputCertificate=nil;pointwiseSamplerCertificate=nil }
  private func poisonPointwiseInput() throws {
    guard CVPixelBufferLockBaseAddress(pixelBuffer,[]) == kCVReturnSuccess else { throw RawBaseCacheError.unavailable }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer,[]) }
    guard let address=CVPixelBufferGetBaseAddress(pixelBuffer) else { throw RawBaseCacheError.unavailable }
    PreviewNativePointwiseCertificateV1.poison(address:address,width:width,height:height,rowBytes:rowBytes)
  }
  private func scanPointwiseInput(authority:String) throws -> PreviewNativePointwiseCertificateV1.Input {
    guard CVPixelBufferLockBaseAddress(pixelBuffer,.readOnly) == kCVReturnSuccess else { throw RawBaseCacheError.unavailable }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer,.readOnly) }
    guard let address=CVPixelBufferGetBaseAddress(pixelBuffer) else { throw RawBaseCacheError.unavailable }
    return try PreviewNativePointwiseCertificateV1.scan(address:UnsafeRawPointer(address),width:width,height:height,
      rowBytes:rowBytes,owner:ownerIncarnation,authority:authority)
  }
  func validateFinite() throws {
    guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { throw RawBaseCacheError.unavailable }
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw RawBaseCacheError.unavailable }
    for row in 0..<height {
      let values = base.advanced(by: row * rowBytes).assumingMemoryBound(to: Float.self)
      for index in 0..<(width * 4) where !values[index].isFinite { throw DevelopmentError.invalidEncoding }
    }
  }
}
