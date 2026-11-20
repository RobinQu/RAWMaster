import AppKit
import CoreImage
import Metal
import XCTest
@testable import RAWMasterImaging

final class PreviewSharedSurfaceTests: XCTestCase {
  private final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var value = 0
    func add() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
  }
  /// Pure CPU fixture, explicitly not a simulated GPU-completion witness.
  private final class CPUFixture: PreviewSharedImageBacking {
    let sharedImageLayout: PreviewSharedSurfaceLayout
    private let lock = NSLock()
    private var bytes: UnsafeMutableRawPointer?
    private let ticket: PreviewPresentationReservation
    let releases: Counter
    init(ledger: PreviewPresentationLedger, releases: Counter) throws {
      let layout = try PreviewSharedSurfaceLayout.make(width: 3, height: 2)
      sharedImageLayout = layout; self.releases = releases
      ticket = try ledger.reserveCPUFallback(bytes: layout.allocationBytes)
      bytes = .allocate(byteCount: layout.allocationBytes, alignment: 64)
      do { try ticket.registerActualAllocation(bytes: layout.allocationBytes) }
      catch { bytes!.deallocate(); bytes = nil; ticket.releaseAfterStorageReleased(); throw error }
      bytes!.initializeMemory(as: UInt8.self, repeating: 0xA5, count: layout.allocationBytes)
      let pixels: [[UInt8]] = [[0,0,0,0, 3,7,11,128, 255,0,0,255],
                               [0,255,0,255, 0,0,255,255, 127,127,127,127]]
      for row in 0..<2 { pixels[row].withUnsafeBytes { bytes!.advanced(by: row * layout.rowBytes).copyMemory(from: $0.baseAddress!, byteCount: $0.count) } }
    }
    var sharedImageBaseAddress: UnsafeRawPointer { lock.lock(); defer { lock.unlock() }; return UnsafeRawPointer(bytes!) }
    func sharedImageProviderDidRelease() {
      lock.lock(); defer { lock.unlock() }; guard let bytes else { return }
      self.bytes = nil; bytes.deallocate(); releases.add(); ticket.releaseAfterStorageReleased()
    }
    deinit { sharedImageProviderDidRelease() }
  }

  func testLayoutPaddingAndCPUFallbackUnionNeverBypassesCapacity() throws {
    let layout = try PreviewSharedSurfaceLayout.make(width: 3, height: 2)
    XCTAssertGreaterThanOrEqual(layout.rowBytes, 12)
    XCTAssertGreaterThanOrEqual(layout.allocationBytes, layout.rowBytes * 2)
    XCTAssertThrowsError(try PreviewSharedSurfaceLayout.make(width: 0, height: 2))
    let ledger = PreviewPresentationLedger(cpuBudget: 100, gpuBudget: 60)
    let shared = try ledger.reserveSharedSurface(bytes: 60)
    try shared.registerActualAllocation(bytes: 60)
    XCTAssertThrowsError(try ledger.reserveSharedSurface(bytes: 1)) { XCTAssertEqual($0 as? PreviewPresentationError, .displayCapacity) }
    let fallback = try ledger.reserveCPUFallback(bytes: 40)
    try fallback.registerActualAllocation(bytes: 40)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 100); XCTAssertEqual(ledger.statistics.chargedGPUBytes, 60)
    XCTAssertThrowsError(try ledger.reserveCPUFallback(bytes: 1)) { XCTAssertEqual($0 as? PreviewPresentationError, .displayCapacity) }
    let retired = ledger.closeAdmissionAndRetire()
    XCTAssertEqual(retired.retiredCPUBytes, 100); XCTAssertEqual(retired.retiredGPUBytes, 60)
    XCTAssertThrowsError(try ledger.reserveCPUFallback(bytes: 1)) { XCTAssertEqual($0 as? PreviewPresentationError, .closed) }
    fallback.releaseAfterStorageReleased(); shared.releaseAfterStorageReleased()
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0); XCTAssertEqual(ledger.statistics.chargedGPUBytes, 0)
  }

  func testActualOverrunRemainsChargedUntilReleaseAndDuplicateReleaseIsSafe() throws {
    let ledger = PreviewPresentationLedger(cpuBudget: 100, gpuBudget: 100)
    let ticket = try ledger.reserveSharedSurface(bytes: 80)
    XCTAssertThrowsError(try ticket.registerActualAllocation(bytes: 120)) { XCTAssertEqual($0 as? PreviewPresentationError, .allocationProtocol) }
    XCTAssertEqual(ledger.statistics.allocatedCPUBytes, 120); XCTAssertEqual(ledger.statistics.allocatedGPUBytes, 120)
    XCTAssertThrowsError(try ledger.reserveCPUFallback(bytes: 1))
    DispatchQueue.concurrentPerform(iterations: 32) { _ in ticket.releaseAfterStorageReleased() }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0); XCTAssertEqual(ledger.statistics.allocations, 0)
    // Retaining this released ticket is not retaining an allocation/accounting entry.
    withExtendedLifetime(ticket) { XCTAssertEqual(ledger.statistics.reservedCPUBytes, 0) }
  }

  func testCloseDuringAllocationChargesActualThenRejectsAndDoesNotWaitForCaller() throws {
    let ledger = PreviewPresentationLedger(cpuBudget: 100, gpuBudget: 100)
    let ticket = try ledger.reserveSharedSurface(bytes: 80)
    _ = ledger.closeAdmissionAndRetire()
    XCTAssertThrowsError(try ticket.registerActualAllocation(bytes: 80)) { XCTAssertEqual($0 as? PreviewPresentationError, .closed) }
    XCTAssertEqual(ledger.statistics.allocatedCPUBytes, 80); XCTAssertEqual(ledger.statistics.retiredCPUBytes, 80)
    ticket.releaseAfterStorageReleased(); XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0)
  }

  func testPureBGRAProviderRowsPaddingICCAlphaBitwiseAndRetainedImagesAcrossClose() throws {
    let ledger = PreviewPresentationLedger(), count = Counter()
    try autoreleasepool {
      var fixture: CPUFixture? = try CPUFixture(ledger: ledger, releases: count)
      weak var weakFixture = fixture
      let layout = fixture!.sharedImageLayout
      let expected = Data(bytes: fixture!.sharedImageBaseAddress, count: layout.rowBytes * layout.height)
      var cg: CGImage? = try PreviewSharedImageBridge.makeCGImage(backing: fixture!)
      var image: NSImage? = NSImage(cgImage: cg!, size: NSSize(width: layout.width, height: layout.height))
      fixture = nil
      XCTAssertNotNil(weakFixture); XCTAssertEqual(count.count, 0)
      let closed = ledger.closeAdmissionAndRetire()
      XCTAssertEqual(closed.retiredCPUBytes, layout.allocationBytes)
      XCTAssertEqual(cg!.bitsPerComponent, 8); XCTAssertEqual(cg!.bitsPerPixel, 32)
      XCTAssertEqual(cg!.bytesPerRow, layout.rowBytes); XCTAssertEqual(cg!.alphaInfo, .premultipliedFirst)
      XCTAssertEqual(cg!.bitmapInfo.intersection(.byteOrderMask), .byteOrder32Little)
      XCTAssertEqual(cg!.colorSpace?.name as String?, CGColorSpace.sRGB as String)
      XCTAssertFalse((cg!.colorSpace?.copyICCData() as Data? ?? Data()).isEmpty)
      // dataProvider.data copy is test-only and tiny; production never requests it.
      XCTAssertEqual(cg!.dataProvider!.data! as Data, expected)
      XCTAssertEqual(Array(expected[0..<12]), [0,0,0,0,3,7,11,128,255,0,0,255])
      if layout.rowBytes > 12 { XCTAssertEqual(expected[12], 0xA5) }
      cg = nil // The retained NSImage must independently keep valid backing pixels.
      XCTAssertNotNil(image); XCTAssertNotNil(weakFixture)
      image = nil
    }
    XCTAssertEqual(count.count, 1)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0)
  }

  private func gpuDevice() throws -> any MTLDevice {
    guard ProcessInfo.processInfo.environment["RAWMASTER_P4_A0_GPU_TINY"] == "1" else { throw XCTSkip("Root must explicitly authorize tiny GPU execution") }
    guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else { throw XCTSkip("This prototype requires a shared-memory Metal device") }
    return device
  }
  private func imageFixture() -> CIImage {
    var values = [Float]()
    for y in 0..<3 { for x in 0..<5 {
      let alpha: Float = x == 0 ? 0 : (x == 1 ? 0.5 : 1)
      values += [Float(x)/4 * alpha, Float(y)/2 * alpha, (x == 4 ? 1.25:0.2) * alpha, alpha]
    } }
    let data = values.withUnsafeBytes { Data($0) }
    return CIImage(bitmapData: data, bytesPerRow: 5 * 16, size: CGSize(width: 5, height: 3), format: .RGBAf,
                   colorSpace: DevelopmentColorEngineV2.linearSRGB)
  }
  func testRealGPUJoinedImageMatchesOldMaterializerAndReleasedProviderDrains() throws {
    let device = try gpuDevice(), ledger = PreviewPresentationLedger(), image = imageFixture()
    let context = CIContext(mtlDevice: device, options: [.workingColorSpace: DevelopmentColorEngineV2.linearSRGB,
      .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false, .memoryTarget: 512])
    // Exact existing full-image finite validator, not a sample/FIT substitute.
    try DevelopmentColorEngineV2.validateFinite(image, context: context)
    let cg = try XCTUnwrap(context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: PhotoRenderer.sRGB, deferred: false))
    let owned = try XCTUnwrap(CGContext(data: nil, width: 5, height: 3, bitsPerComponent: 8, bytesPerRow: 20,
      space: PhotoRenderer.sRGB, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
    owned.setBlendMode(.copy); owned.interpolationQuality = .none
    owned.draw(cg, in: CGRect(x: 0, y: 0, width: 5, height: 3))
    let baseline = Data(bytes: try XCTUnwrap(owned.data), count: 60)
    try autoreleasepool {
      var result: PreviewSharedSurfaceImage? = try PreviewSharedSurfaceStorage.materialize(image, device: device, ledger: ledger)
      XCTAssertTrue(result!.gpuJoined); XCTAssertEqual(ledger.statistics.allocatedGPUBytes, result!.actualAllocationBytes)
      let bytes = result!.cgImage.dataProvider!.data! as Data
      var errors = [[Int]](repeating: [], count: 4)
      for y in 0..<3 { for x in 0..<5 { for c in 0..<4 {
        let swizzle = [2,1,0,3][c]
        errors[c].append(abs(Int(bytes[y * result!.layout.rowBytes + x * 4 + swizzle]) - Int(baseline[y * 20 + x * 4 + c])))
      } } }
      for channel in errors {
        XCTAssertLessThanOrEqual(channel.max()!, 2)
        let sorted = channel.sorted(), position = Double(channel.count - 1) * 0.99
        let lo = Int(floor(position)), hi = Int(ceil(position))
        let p99 = lo == hi ? Double(sorted[lo]) : Double(sorted[lo]) * (Double(hi) - position) + Double(sorted[hi]) * (position - Double(lo))
        XCTAssertLessThanOrEqual(p99, 1)
      }
      _ = ledger.closeAdmissionAndRetire()
      XCTAssertGreaterThan(ledger.statistics.retiredCPUBytes, 0)
      result = nil
    }
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0); XCTAssertEqual(ledger.statistics.chargedGPUBytes, 0)
    XCTAssertEqual(ledger.statistics.cleanupFailures, 0)
  }
  func testRealGPUCloseAfterSubmitStillJoinsAndDoesNotPublishOrFallback() throws {
    let device = try gpuDevice(), ledger = PreviewPresentationLedger(), joined = Counter()
    XCTAssertThrowsError(try PreviewSharedSurfaceStorage.materialize(imageFixture(), device: device, ledger: ledger) { phase in
      if phase == "display-gpu-submitted" { _ = ledger.closeAdmissionAndRetire() }
      if phase == "display-gpu-joined" { joined.add() }
    }) { XCTAssertEqual($0 as? PreviewPresentationError, .closed) }
    XCTAssertEqual(joined.count, 1); XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0)
    XCTAssertEqual(ledger.statistics.chargedGPUBytes, 0)
  }
}
