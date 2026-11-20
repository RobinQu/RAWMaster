import AppKit
import CoreImage
import CoreVideo
import IOSurface
import Metal
import Darwin

struct PreviewSharedSurfaceLayout: Equatable {
  let width: Int, height: Int, rowBytes: Int, allocationBytes: Int
  static func make(width: Int, height: Int) throws -> Self {
    guard width > 0, height > 0, width <= 16_384, height <= 16_384 else { throw PreviewPresentationError.invalidLayout }
    let (tight, overflow) = width.multipliedReportingOverflow(by: 4)
    guard !overflow else { throw PreviewPresentationError.invalidLayout }
    let row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, tight)
    let (size, sizeOverflow) = row.multipliedReportingOverflow(by: height)
    let page = Int(getpagesize())
    guard row >= tight, !sizeOverflow, size > 0, size <= Int.max - page else { throw PreviewPresentationError.invalidLayout }
    return .init(width: width, height: height, rowBytes: row, allocationBytes: ((size + page - 1) / page) * page)
  }
}

/// A leaf bridge over immutable REAL CPU bytes. A CPU fixture may implement this
/// protocol to test row/channel/provider lifetime without pretending a GPU ran.
protocol PreviewSharedImageBacking: AnyObject {
  var sharedImageBaseAddress: UnsafeRawPointer { get }
  var sharedImageLayout: PreviewSharedSurfaceLayout { get }
  func sharedImageProviderDidRelease()
}

enum PreviewSharedImageBridge {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
  static let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
  private final class ReleaseBox {
    private let lock = NSLock()
    private var backing: (any PreviewSharedImageBacking)?
    init(_ backing: any PreviewSharedImageBacking) { self.backing = backing }
    func finish() {
      lock.lock(); let value = backing; backing = nil; lock.unlock()
      value?.sharedImageProviderDidRelease()
    }
    deinit { finish() }
  }
  /// Does not take ownership of arbitrary malloc bytes: the backing owns their
  /// lifetime and must already have completed its producer/CPU-read preparation.
  static func makeCGImage(backing: any PreviewSharedImageBacking) throws -> CGImage {
    let layout = backing.sharedImageLayout
    let (count, overflow) = layout.rowBytes.multipliedReportingOverflow(by: layout.height)
    guard layout.width > 0, layout.height > 0, layout.width <= 16_384, layout.height <= 16_384,
          layout.rowBytes >= layout.width * 4, !overflow, count > 0,
          layout.allocationBytes >= count else { throw PreviewPresentationError.invalidLayout }
    let box = ReleaseBox(backing), opaque = Unmanaged.passRetained(box).toOpaque()
    guard let provider = CGDataProvider(dataInfo: opaque, data: backing.sharedImageBaseAddress,
      size: count, releaseData: { info, _, _ in
        guard let info else { return }
        Unmanaged<ReleaseBox>.fromOpaque(info).takeRetainedValue().finish()
      }) else {
      Unmanaged<ReleaseBox>.fromOpaque(opaque).takeRetainedValue().finish()
      throw PreviewPresentationError.imageCreationFailed
    }
    guard let image = CGImage(width: layout.width, height: layout.height, bitsPerComponent: 8, bitsPerPixel: 32,
      bytesPerRow: layout.rowBytes, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider,
      decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw PreviewPresentationError.imageCreationFailed }
    return image
  }
}

struct PreviewSharedSurfaceImage {
  let image: NSImage
  let cgImage: CGImage
  let layout: PreviewSharedSurfaceLayout
  let allocationID: UUID
  let actualAllocationBytes: Int
  let gpuJoined: Bool
}

/// Independent opt-in primitive, NOT wired to preview/canonical/default clients.
/// Caller supplies its already finite-validated final graph. Full finite coverage
/// and RAW EV remain the existing engine's responsibility, not a FIT-only check.
final class PreviewSharedSurfaceStorage: PreviewSharedImageBacking {
  private enum Phase { case allocated, rendering, gpuJoined, readLocked, providerOwned, released }
  private let lock = NSLock()
  private var phase: Phase = .allocated
  private var surface: IOSurface?
  private var texture: (any MTLTexture)?
  private let reservation: PreviewPresentationReservation
  let sharedImageLayout: PreviewSharedSurfaceLayout
  let actualAllocationBytes: Int
  private init(surface: IOSurface, texture: any MTLTexture, reservation: PreviewPresentationReservation,
               layout: PreviewSharedSurfaceLayout, actual: Int) {
    self.surface = surface; self.texture = texture; self.reservation = reservation
    sharedImageLayout = layout; actualAllocationBytes = actual
  }
  private static func allocate(width: Int, height: Int, device: any MTLDevice,
                               ledger: PreviewPresentationLedger, scope: PreviewPresentationScope?) throws -> PreviewSharedSurfaceStorage {
    guard device.hasUnifiedMemory else { throw PreviewPresentationError.unsupported }
    let layout = try PreviewSharedSurfaceLayout.make(width: width, height: height)
    let reservation: PreviewPresentationReservation
    if let scope {
      guard scope.ledger === ledger else { throw PreviewPresentationError.allocationProtocol }
      reservation = try scope.reserveSharedSurface(bytes: layout.allocationBytes)
    } else { reservation = try ledger.reserveSharedSurface(bytes: layout.allocationBytes) }
    var surface: IOSurface?, texture: (any MTLTexture)?
    do {
      try reservation.requireOpenAdmission()
      let properties: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height,
        kIOSurfaceBytesPerRow: layout.rowBytes, kIOSurfaceBytesPerElement: 4,
        kIOSurfaceAllocSize: layout.allocationBytes, kIOSurfacePixelFormat: kCVPixelFormatType_32BGRA]
      surface = IOSurfaceCreate(properties as CFDictionary)
      guard surface != nil else { throw PreviewPresentationError.unsupported }
      let actual = IOSurfaceGetAllocSize(surface!)
      try reservation.registerActualAllocation(bytes: actual)
      guard actual >= layout.rowBytes * height, IOSurfaceGetBytesPerRow(surface!) == layout.rowBytes,
            IOSurfaceGetWidth(surface!) == width, IOSurfaceGetHeight(surface!) == height,
            IOSurfaceGetPixelFormat(surface!) == kCVPixelFormatType_32BGRA else { throw PreviewPresentationError.allocationProtocol }
      let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
      descriptor.storageMode = .shared; descriptor.cpuCacheMode = .defaultCache
      descriptor.hazardTrackingMode = .tracked; descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
      texture = device.makeTexture(descriptor: descriptor, iosurface: surface!, plane: 0)
      guard let created = texture, created.storageMode == .shared, created.pixelFormat == .bgra8Unorm,
            created.width == width, created.height == height,
            let backing = created.iosurface, IOSurfaceGetID(backing) == IOSurfaceGetID(surface!) else { throw PreviewPresentationError.unsupported }
      let owner = PreviewSharedSurfaceStorage(surface: surface!, texture: created, reservation: reservation, layout: layout, actual: actual)
      texture = nil; surface = nil; return owner
    } catch {
      texture = nil; surface = nil // Clear real storage before accounting, including over-allocation.
      reservation.releaseAfterStorageReleased(); throw error
    }
  }
  static func materialize(_ image: CIImage, device: any MTLDevice, ledger: PreviewPresentationLedger,
                          memoryHintMiB: Int = 512, scope: PreviewPresentationScope? = nil,
                          observation: ((String) -> Void)? = nil) throws -> PreviewSharedSurfaceImage {
    guard image.extent.minX == 0, image.extent.minY == 0, image.extent == image.extent.integral,
          image.extent.width.isFinite, image.extent.height.isFinite,
          image.extent.width > 0, image.extent.height > 0,
          image.extent.width <= 16_384, image.extent.height <= 16_384 else { throw PreviewPresentationError.invalidLayout }
    let owner = try allocate(width: Int(image.extent.width), height: Int(image.extent.height), device: device, ledger: ledger, scope: scope)
    do {
      // Every graph/context/destination/task view drains before publishing CPU bytes.
      try autoreleasepool { try owner.renderAndJoin(image, device: device, memoryHintMiB: memoryHintMiB, observation: observation) }
      try Task.checkCancellation(); try owner.reservation.requireOpenAdmission()
      try owner.prepareCPURead()
      let cg = try PreviewSharedImageBridge.makeCGImage(backing: owner)
      owner.lock.lock()
      guard owner.phase == .readLocked else { owner.lock.unlock(); throw PreviewPresentationError.imageCreationFailed }
      owner.phase = .providerOwned; owner.lock.unlock()
      let size = NSSize(width: owner.sharedImageLayout.width, height: owner.sharedImageLayout.height)
      let image = NSImage(cgImage: cg, size: size)
      try Task.checkCancellation(); try owner.reservation.requireOpenAdmission()
      return .init(image: image, cgImage: cg, layout: owner.sharedImageLayout,
                   allocationID: owner.reservation.id, actualAllocationBytes: owner.actualAllocationBytes, gpuJoined: true)
    } catch {
      // Once a CG provider exists, only its final callback may invalidate bytes.
      // Unwinding a cancelled factory must not free storage under a live CGImage.
      owner.releaseUnpublishedResources(); throw error
    }
  }
  private func renderAndJoin(_ image: CIImage, device: any MTLDevice, memoryHintMiB: Int,
                             observation: ((String) -> Void)?) throws {
    try reservation.requireOpenAdmission()
    lock.lock(); guard phase == .allocated, let texture else { lock.unlock(); throw PreviewPresentationError.closed }
    phase = .rendering; lock.unlock()
    guard let queue = device.makeCommandQueue() else {
      lock.lock(); phase = .gpuJoined; lock.unlock(); throw PreviewPresentationError.unsupported
    }
    let context = CIContext(mtlCommandQueue: queue, options: [.workingColorSpace: DevelopmentColorEngineV2.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: max(1, min(512, memoryHintMiB))])
    defer { context.clearCaches() }
    let destination = CIRenderDestination(mtlTexture: texture, commandBuffer: nil)
    destination.colorSpace = PreviewSharedImageBridge.colorSpace; destination.alphaMode = .premultiplied
    destination.isFlipped = true; destination.isClamped = true; destination.isDithered = false
    var task: CIRenderTask?
    do {
      task = try context.startTask(toRender: image, to: destination)
      observation?("display-gpu-submitted")
      _ = try task!.waitUntilCompleted()
      lock.lock(); phase = .gpuJoined; lock.unlock()
      observation?("display-gpu-joined")
      try Task.checkCancellation(); try reservation.requireOpenAdmission()
    } catch {
      // Never treat caller cancellation or a thrown GPU error as a permit release.
      // A returned task is always actually waited, including its failure completion.
      if let task { _ = try? task.waitUntilCompleted() }
      lock.lock(); phase = .gpuJoined; lock.unlock()
      throw error
    }
  }
  private func prepareCPURead() throws {
    lock.lock(); defer { lock.unlock() }
    guard phase == .gpuJoined, let surface else { throw PreviewPresentationError.closed }
    guard IOSurfaceLock(surface, .readOnly, nil) == KERN_SUCCESS else { throw PreviewPresentationError.cpuLockFailed }
    phase = .readLocked
    guard IOSurfaceGetBaseAddress(surface) != nil else { throw PreviewPresentationError.cpuLockFailed }
  }
  var sharedImageBaseAddress: UnsafeRawPointer {
    lock.lock(); defer { lock.unlock() }
    precondition(phase == .readLocked || phase == .providerOwned)
    return UnsafeRawPointer(IOSurfaceGetBaseAddress(surface!))
  }
  func sharedImageProviderDidRelease() { releaseResourcesAfterJoinedProducer() }
  private func releaseUnpublishedResources() {
    lock.lock(); let providerOwnsBytes = phase == .providerOwned; lock.unlock()
    if !providerOwnsBytes { releaseResourcesAfterJoinedProducer() }
  }
  private func releaseResourcesAfterJoinedProducer() {
    lock.lock(); defer { lock.unlock() }
    guard phase != .released else { return }
    precondition(phase != .rendering, "GPU producer must actually join before storage release")
    if (phase == .readLocked || phase == .providerOwned), let surface,
       IOSurfaceUnlock(surface, .readOnly, nil) != KERN_SUCCESS { reservation.recordCleanupFailure() }
    texture = nil; surface = nil; phase = .released
    reservation.releaseAfterStorageReleased()
  }
  deinit { releaseResourcesAfterJoinedProducer() }
}
