import AppKit

/// A revisited slider value can reuse the last full-quality render at this size.
/// The provider owns a charged display copy so retaining a canvas after eviction
/// still participates in the same per-process presentation budget as a GPU frame.
final class PreviewSettledDisplayReplay: PreviewSharedImageBacking {
  let sharedImageLayout: PreviewSharedSurfaceLayout
  private let bytes: UnsafeMutableRawPointer
  private let ticket: PreviewPresentationReservation
  var sharedImageBaseAddress: UnsafeRawPointer { UnsafeRawPointer(bytes) }

  private init(layout: PreviewSharedSurfaceLayout, ticket: PreviewPresentationReservation) throws {
    self.sharedImageLayout = layout
    self.ticket = ticket
    bytes = .allocate(byteCount: layout.allocationBytes, alignment: 64)
    try ticket.registerActualAllocation(bytes: layout.allocationBytes)
  }

  func sharedImageProviderDidRelease() {}
  deinit {
    bytes.deallocate()
    ticket.releaseAfterStorageReleased()
  }

  static func make(_ original: PreviewPixels, key: String, size: PreviewInteractiveLayout, scope: PreviewPresentationScope,
                   check: () throws -> Void) throws -> PreviewPixels? {
    guard !original.managedPresentation, original.approximation == nil,
          original.outputSize == CGSize(width: size.width,height: size.height),
          let image = original.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          image.width == size.width, image.height == size.height else { return nil }
    try check()
    let layout = try PreviewSharedSurfaceLayout.make(width: image.width, height: image.height)
    let ticket: PreviewPresentationReservation
    do { ticket = try scope.reserveCPUFallback(bytes: layout.allocationBytes) }
    catch PreviewPresentationError.displayCapacity { return nil }
    let token = ImagePerformanceTelemetry.shared.begin(operation: "交互预览",stage: "复用已定稿画面",queue: "预览",boundary: .apiReturn)
    var success = false
    defer { ImagePerformanceTelemetry.shared.end(token,outcome: success ? .succeeded : .failed,pixelCount: success ? image.width*image.height : 0) }
    let copy = try PreviewSettledDisplayReplay(layout: layout, ticket: ticket)
    guard let context = CGContext(data: copy.bytes,width: image.width,height: image.height,bitsPerComponent: 8,
        bytesPerRow: layout.rowBytes,space: PreviewSharedImageBridge.colorSpace,bitmapInfo: PreviewSharedImageBridge.bitmapInfo.rawValue) else {
      return nil
    }
    context.setBlendMode(.copy)
    context.interpolationQuality = .none
    context.draw(image,in: CGRect(origin: .zero,size: original.outputSize))
    context.flush()
    try check()
    try ticket.requireOpenAdmission()
    let raster = try PreviewSharedImageBridge.makeCGImage(backing: copy)
    success = true
    return PreviewPixels(image: PreviewSharedImageBridge.presentationImage(raster,backing: copy),nativeSize: original.nativeSize,
      outputSize: original.outputSize,bytes: layout.allocationBytes,settledReplayKey: key,presentationTicket: ticket)
  }
}
