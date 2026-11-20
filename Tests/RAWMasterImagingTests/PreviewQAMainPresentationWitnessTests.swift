import XCTest
import AppKit
import CoreImage
import Metal
@testable import RAWMasterImaging

final class PreviewQAMainPresentationWitnessTests: XCTestCase {
  @MainActor func testOptInBoundAndWeakRegistryDoNotRetainImages() throws {
    let id = "io.robinqu.RAWMaster.preview022"
    let env = ["RAWMASTER_QA_NATIVE_POINTWISE_V1":"1", "RAWMASTER_INTERACTION_TRACE":"/tmp/trace.jsonl",
               "RAWMASTER_QA_MAIN_PRESENTATION_OWNER_V1":"1"]
    XCTAssertTrue(PreviewQAMainPresentationWitness.enabled(bundleIdentifier: id, environment: env))
    XCTAssertFalse(PreviewQAMainPresentationWitness.enabled(bundleIdentifier: "io.robinqu.RAWMaster", environment: env))
    for key in env.keys {
      var missing = env; missing.removeValue(forKey: key)
      XCTAssertFalse(PreviewQAMainPresentationWitness.enabled(bundleIdentifier: id, environment: missing))
    }
    let ledger = PreviewPresentationLedger()
    let store = PreviewQAMainPresentationWitness.Store(ledger: ledger)
    var records = [PreviewQAMainPresentationWitness.Record]()
    for _ in 0..<32 {
      autoreleasepool {
        let image = NSImage(size: .init(width: 4, height: 4)), ticketID = UUID()
        if let record = store.register(image: image, ticketID: ticketID, bytes: 64) { records.append(record) }
        XCTAssertNil(store.register(image: image, ticketID: ticketID, bytes: 64))
        XCTAssertTrue(store.contains(ticketID))
      }
    }
    let rejected = UUID()
    let overflow = store.register(image: NSImage(size: .init(width: 4, height: 4)), ticketID: rejected, bytes: 64)
    XCTAssertEqual(overflow?.phase, "registry-overflow")
    XCTAssertNil(store.register(image: NSImage(size: .init(width: 4, height: 4)), ticketID: UUID(), bytes: 64))
    XCTAssertFalse(store.contains(rejected))
    XCTAssertNil(store.providerReleased(ticketID: rejected, closeSucceeded: true))
    let snapshot = store.snapshot("test", controller: nil, primary: nil, comparison: nil)
    XCTAssertEqual(snapshot.registeredCount, 32)
    XCTAssertTrue(snapshot.registryOverflow)
    XCTAssertTrue(snapshot.images.allSatisfy { !$0.weakImageAlive && !$0.ledger.present })
    XCTAssertEqual(records.count, 32) // Keeping encoded records never keeps an image.
    XCTAssertFalse(try JSONEncoder().encode(snapshot).isEmpty)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0)
  }

  /// No GPU: the actual CG provider owns these CPU bytes until its final CG alias exits.
  @MainActor func testRealProviderCallbackAndEscapedCGAliasRemainDistinctFromWeakNSImage() throws {
    let ledger = PreviewPresentationLedger(), scope = PreviewPresentationScope(ledgerForTesting: ledger)
    let store = PreviewQAMainPresentationWitness.Store(ledger: ledger)
    let ticket = try scope.reserveCPUFallback(bytes: 64)
    try ticket.registerActualAllocation(bytes: 64)
    let id = ticket.id
    var heldImage: NSImage?, escapedCG: CGImage?
    try autoreleasepool {
      let owner = BytesOwner(ticket: ticket, store: store)
      let info = Unmanaged.passRetained(owner).toOpaque()
      guard let provider = CGDataProvider(dataInfo: info, data: owner.pointer, size: 64, releaseData: { info, _, _ in
        guard let info else { return }
        let owner = Unmanaged<BytesOwner>.fromOpaque(info).takeRetainedValue()
        owner.releaseStorage()
      }) else {
        Unmanaged<BytesOwner>.fromOpaque(info).takeRetainedValue().releaseStorage()
        throw PreviewPresentationError.imageCreationFailed
      }
      let cg = try XCTUnwrap(CGImage(width: 4, height: 4, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
        space: PhotoRenderer.sRGB, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
      let image = NSImage(cgImage: cg, size: .init(width: 4, height: 4))
      heldImage = image; escapedCG = cg
      XCTAssertNotNil(store.register(image: image, ticketID: id, bytes: 64))
    }
    scope.closeAndRetire()
    var record = store.snapshot("retired-with-slots", controller: heldImage, primary: heldImage, comparison: nil)
    let first = try XCTUnwrap(record.images.first)
    XCTAssertTrue(first.weakImageAlive && first.controllerMatches && first.primaryMatches)
    XCTAssertFalse(first.comparisonMatches)
    XCTAssertEqual(first.ledger.allocatedBytes, 64); XCTAssertEqual(first.ledger.retired, true)
    XCTAssertEqual(first.providerCallbackCount, 0)
    heldImage = nil
    autoreleasepool {}
    record = store.snapshot("only-escaped-CG", controller: nil, primary: nil, comparison: nil)
    let second = try XCTUnwrap(record.images.first)
    XCTAssertFalse(second.weakImageAlive)
    XCTAssertTrue(second.ledger.present); XCTAssertEqual(second.providerCallbackCount, 0)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes, 64)
    withExtendedLifetime(escapedCG) {}
    escapedCG = nil
    autoreleasepool {}
    record = store.snapshot("provider-released", controller: nil, primary: nil, comparison: nil)
    let final = try XCTUnwrap(record.images.first)
    XCTAssertFalse(final.weakImageAlive); XCTAssertFalse(final.ledger.present)
    XCTAssertEqual(final.providerCallbackCount, 1); XCTAssertEqual(final.providerCloseSucceeded, true)
    XCTAssertNotNil(final.providerCallbackNS)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes, 0)
    XCTAssertEqual(ledger.statistics.cleanupFailures, 0)
  }

  @MainActor func testManagedOutputSeparatesImageCGAliasAndStorageRelease() throws {
    let ledger = PreviewPresentationLedger(), scope = PreviewPresentationScope(ledgerForTesting: ledger)
    let store = PreviewQAMainPresentationWitness.Store(ledger: ledger)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let context = CIContext(mtlDevice: device)
    let layout = try PreviewInteractiveLayout.make(width: 8, height: 8, float: false)
    var heldImage: NSImage?, escapedCG: CGImage?, heldStorage: PreviewInteractiveProxyStorage?
    weak var imageWitness: NSImage?
    weak var storageWitness: PreviewInteractiveProxyStorage?
    defer {
      // The optional synchronous observer may deliberately hold a storage even if materialize throws.
      heldImage = nil; escapedCG = nil; heldStorage = nil
      context.clearCaches(); scope.closeAndRetire(); autoreleasepool {}
      XCTAssertEqual(ledger.statistics.chargedCPUBytes + ledger.statistics.chargedGPUBytes, 0)
      XCTAssertEqual(ledger.statistics.cleanupFailures, 0)
    }
    let ticket = try scope.reserveSharedSurface(bytes: layout.bytes)
    let id = ticket.id
    try autoreleasepool {
      let output = PreviewInteractiveManagedOutput(layout: layout, ticket: ticket, device: device,
        qaMainOwnerStoreForTesting: store)
      let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
      let pixels = try output.materialize(source, context: context, nativeSize: CGSize(width: 8, height: 8),
        storageObserverForTesting: { heldStorage = $0; storageWitness = $0 }, check: {})
      heldImage = pixels.image; imageWitness = pixels.image
      escapedCG = try XCTUnwrap(pixels.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
      let cg = try XCTUnwrap(escapedCG)
      XCTAssertEqual(cg.width, 8); XCTAssertEqual(cg.height, 8)
      let data = try XCTUnwrap(cg.dataProvider?.data)
      let bytes = try XCTUnwrap(CFDataGetBytePtr(data))
      // Actual shared BGRA output from a joined render, independently known red/opaque.
      XCTAssertEqual(Array(UnsafeBufferPointer(start: bytes, count: 4)), [0, 0, 255, 255])
    }
    XCTAssertTrue(store.contains(id), "The actual materialize publication must register its real image")
    scope.closeAndRetire()
    var records = [store.snapshot("published", controller: heldImage, primary: nil, comparison: nil)]
    var state = try XCTUnwrap(records.last?.images.first)
    XCTAssertTrue(state.imageRegistered && state.weakImageAlive && state.controllerMatches)
    XCTAssertTrue(state.ledger.present); XCTAssertEqual(state.ledger.retired, true)
    XCTAssertEqual(state.managedUnlockCount, 0); XCTAssertEqual(state.managedStorageReleaseCount, 0)
    heldImage = nil
    autoreleasepool {}
    records.append(store.snapshot("CG-and-storage", controller: nil, primary: nil, comparison: nil))
    state = try XCTUnwrap(records.last?.images.first)
    XCTAssertNil(imageWitness)
    XCTAssertFalse(state.weakImageAlive); XCTAssertTrue(state.ledger.present)
    XCTAssertEqual(state.managedUnlockCount, 0)
    withExtendedLifetime(escapedCG) {}
    escapedCG = nil
    autoreleasepool {}
    records.append(store.snapshot("only-storage", controller: nil, primary: nil, comparison: nil))
    state = try XCTUnwrap(records.last?.images.first)
    XCTAssertNotNil(storageWitness)
    XCTAssertEqual(state.managedUnlockCount, 1)
    XCTAssertEqual(state.managedUnlockAttempted, true); XCTAssertEqual(state.managedUnlockStatus, 0)
    XCTAssertEqual(state.managedStorageReleaseCount, 0)
    XCTAssertTrue(state.ledger.present)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes, layout.bytes)
    withExtendedLifetime(heldStorage) {}
    heldStorage = nil
    autoreleasepool {}
    records.append(store.snapshot("storage-released", controller: nil, primary: nil, comparison: nil))
    state = try XCTUnwrap(records.last?.images.first)
    XCTAssertNil(storageWitness); XCTAssertFalse(state.ledger.present)
    XCTAssertEqual(state.managedUnlockCount, 1); XCTAssertEqual(state.managedStorageReleaseCount, 1)
    XCTAssertEqual(state.providerCallbackCount, 0, "The distinct original grain callback was not invoked")
    XCTAssertLessThanOrEqual(try XCTUnwrap(state.managedUnlockNS), try XCTUnwrap(state.managedStorageReleaseNS))
    XCTAssertFalse(try JSONEncoder().encode(records).isEmpty)
    XCTAssertEqual(ledger.statistics.chargedCPUBytes + ledger.statistics.chargedGPUBytes, 0)
    XCTAssertEqual(ledger.statistics.retiredCPUBytes + ledger.statistics.retiredGPUBytes, 0)
  }

  @MainActor func testFailedManagedPublicationKeepsUnknownEventsAndHeldStorageCharged() throws {
    let ledger = PreviewPresentationLedger(), scope = PreviewPresentationScope(ledgerForTesting: ledger)
    let store = PreviewQAMainPresentationWitness.Store(ledger: ledger)
    let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
    let context = CIContext(mtlDevice: device)
    let layout = try PreviewInteractiveLayout.make(width: 8, height: 8, float: false)
    var heldStorage: PreviewInteractiveProxyStorage?
    defer {
      heldStorage = nil; context.clearCaches(); scope.closeAndRetire(); autoreleasepool {}
      XCTAssertEqual(ledger.statistics.chargedCPUBytes + ledger.statistics.chargedGPUBytes, 0)
      XCTAssertEqual(ledger.statistics.cleanupFailures, 0)
    }
    let ticket = try scope.reserveSharedSurface(bytes: layout.bytes)
    var checks = 0
    try autoreleasepool {
      let output = PreviewInteractiveManagedOutput(layout: layout, ticket: ticket, device: device,
        qaMainOwnerStoreForTesting: store)
      let source = CIImage(color: CIColor(red: 1, green: 0, blue: 0, alpha: 1))
        .cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
      do {
        _ = try output.materialize(source, context: context, nativeSize: CGSize(width: 8, height: 8),
          storageObserverForTesting: { heldStorage = $0 }, check: {
            checks += 1
            // The third existing check is after the real fill/wait and CG-backed NSImage creation.
            if checks == 3 { throw CancellationError() }
          })
        XCTFail("The existing publication cancellation guard must still throw")
      } catch is CancellationError {} // No other error is converted to successful cancellation.
    }
    XCTAssertEqual(checks, 3)
    scope.closeAndRetire()
    let failed = store.snapshot("unpublished-but-storage-held", controller: nil, primary: nil, comparison: nil)
    let state = try XCTUnwrap(failed.images.first)
    XCTAssertEqual(failed.registeredCount, 0); XCTAssertFalse(store.contains(ticket.id))
    XCTAssertFalse(state.imageRegistered); XCTAssertFalse(state.weakImageAlive)
    XCTAssertEqual(state.managedUnlockCount, 1); XCTAssertEqual(state.managedUnlockStatus, 0)
    XCTAssertEqual(state.managedStorageReleaseCount, 0)
    XCTAssertTrue(state.ledger.present); XCTAssertEqual(ledger.statistics.retiredCPUBytes, layout.bytes)
    withExtendedLifetime(heldStorage) {}
    heldStorage = nil
    autoreleasepool {}
    let final = try XCTUnwrap(store.snapshot("unpublished-storage-released", controller: nil, primary: nil, comparison: nil).images.first)
    XCTAssertFalse(final.imageRegistered); XCTAssertFalse(final.ledger.present)
    XCTAssertEqual(final.managedUnlockCount, 1); XCTAssertEqual(final.managedStorageReleaseCount, 1)
    XCTAssertEqual(final.providerCallbackCount, 0)
  }

  @MainActor func testEarlyManagedEventsRemainUnknownUntilRealImageRegistrationWithinBound() throws {
    let store = PreviewQAMainPresentationWitness.Store(ledger: PreviewPresentationLedger())
    var ids = [UUID](), records = [PreviewQAMainPresentationWitness.Record]()
    for _ in 0..<32 {
      let id = UUID(); ids.append(id)
      records.append(store.managedUnlocked(ticketID: id, bytes: 64, attempted: true, status: 0))
      XCTAssertFalse(store.contains(id))
    }
    XCTAssertTrue(records.allSatisfy { $0.attributionKnown == false && $0.registeredCount == 0 })
    let before = store.snapshot("early", controller: nil, primary: nil, comparison: nil)
    XCTAssertEqual(before.images.count, 32); XCTAssertEqual(before.registeredCount, 0)
    XCTAssertFalse(before.registryOverflow)
    XCTAssertTrue(before.images.allSatisfy { !$0.imageRegistered && !$0.weakImageAlive && $0.managedUnlockCount == 1 })
    let rejected = UUID()
    let rejectedEvent = store.managedStorageReleased(ticketID: rejected, bytes: 64)
    XCTAssertTrue(rejectedEvent.registryOverflow); XCTAssertEqual(rejectedEvent.attributionKnown, false)
    XCTAssertFalse(store.contains(rejected))
    weak var imageWitness: NSImage?
    autoreleasepool {
      let image = NSImage(size: CGSize(width: 4, height: 4)); imageWitness = image
      let record = store.register(image: image, ticketID: ids[0], bytes: 64)
      XCTAssertEqual(record?.registeredCount, 1); XCTAssertTrue(record?.registryOverflow == true)
      XCTAssertTrue(store.contains(ids[0])); XCTAssertEqual(store.ticketID(for: image), ids[0])
      XCTAssertNil(store.register(image: image, ticketID: ids[0], bytes: 64))
      XCTAssertNil(store.register(image: image, ticketID: rejected, bytes: 64))
    }
    let after = store.snapshot("late-registration", controller: nil, primary: nil, comparison: nil)
    let first = try XCTUnwrap(after.images.first)
    XCTAssertNil(imageWitness); XCTAssertFalse(first.weakImageAlive)
    XCTAssertTrue(first.imageRegistered); XCTAssertEqual(after.registeredCount, 1)
    XCTAssertEqual(after.images.count, 32)
    XCTAssertEqual(first.managedUnlockCount, 1); XCTAssertEqual(first.managedUnlockNS, records[0].atNS)
    XCTAssertFalse(try JSONEncoder().encode([before, after]).isEmpty)
  }

  private final class BytesOwner {
    let pointer = UnsafeMutableRawPointer.allocate(byteCount: 64, alignment: 16)
    let ticket: PreviewPresentationReservation
    let store: PreviewQAMainPresentationWitness.Store
    init(ticket: PreviewPresentationReservation, store: PreviewQAMainPresentationWitness.Store) {
      self.ticket = ticket; self.store = store; pointer.initializeMemory(as: UInt8.self, repeating: 0, count: 64)
    }
    func releaseStorage() {
      pointer.deallocate()
      ticket.releaseAfterStorageReleased()
      _ = store.providerReleased(ticketID: ticket.id, closeSucceeded: true)
    }
  }
}
