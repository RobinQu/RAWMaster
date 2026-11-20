import AppKit
import Foundation

/// QA-only scalar evidence. This owns neither published images nor allocation tickets.
public enum PreviewQAMainPresentationWitness {
  public enum Stage: String {
    case beforeUnmount = "before-unmount", afterUnmount = "after-unmount"
    case afterPreviewShutdown = "after-preview-shutdown", afterCloseAll = "after-closeAll"
    case applicationWillTerminate = "application-will-terminate"
  }
  static func enabled(bundleIdentifier: String?, environment: [String: String]) -> Bool {
    PreviewQALifecycleTrace.enabled(bundleIdentifier: bundleIdentifier, environment: environment) &&
      environment["RAWMASTER_QA_MAIN_PRESENTATION_OWNER_V1"] == "1"
  }
  private static let store: Store? = enabled(bundleIdentifier: Bundle.main.bundleIdentifier,
    environment: ProcessInfo.processInfo.environment) ? Store(ledger: .shared) : nil
  public static var isEnabled: Bool { store != nil }

  static func resolvedStore(_ testing: Store? = nil) -> Store? { testing ?? store }
  static func register(image: NSImage, ticketID: UUID, bytes: Int, testingStore: Store? = nil) {
    guard let store = resolvedStore(testingStore), let record = store.register(image: image, ticketID: ticketID, bytes: bytes) else { return }
    PreviewQALifecycleTrace.recordMainOwner(record)
  }
  static func registeredTicketID(_ id: UUID?) -> UUID? {
    guard let id, let store, store.contains(id) else { return nil }; return id
  }
  /// Called only after the existing provider callback has performed its real close.
  static func providerReleased(ticketID: UUID, closeSucceeded: Bool) {
    guard let store, let record = store.providerReleased(ticketID: ticketID, closeSucceeded: closeSucceeded) else { return }
    PreviewQALifecycleTrace.recordMainOwner(record)
  }
  static func managedUnlocked(store: Store?, ticketID: UUID, bytes: Int, attempted: Bool, status: Int32?) {
    guard let store else { return }
    PreviewQALifecycleTrace.recordMainOwner(store.managedUnlocked(ticketID: ticketID, bytes: bytes,
      attempted: attempted, status: status))
  }
  static func managedStorageReleased(store: Store?, ticketID: UUID, bytes: Int) {
    guard let store else { return }
    PreviewQALifecycleTrace.recordMainOwner(store.managedStorageReleased(ticketID: ticketID, bytes: bytes))
  }
  @MainActor static func canvasCleared(store: Store?, canvasID: UUID?, frameID: UUID?, ticketID: UUID?, fieldsCleared: Bool) {
    guard let store else { return }
    PreviewQALifecycleTrace.recordMainOwner(store.canvasCleared(canvasID: canvasID, frameID: frameID,
      ticketID: ticketID, fieldsCleared: fieldsCleared))
  }
  @MainActor public static func snapshot(_ stage: Stage, controller: NSImage?, primary: NSImage?, comparison: NSImage?) {
    guard let store else { return }
    PreviewQALifecycleTrace.recordMainOwner(store.snapshot(stage.rawValue,
      controller: controller, primary: primary, comparison: comparison))
  }
  public static func flush() { if isEnabled { PreviewQALifecycleTrace.flush() } }

  struct ImageState: Encodable, Sendable {
    let ticketID: UUID, bytes: Int
    let sampleBeganNS: UInt64, sampledNS: UInt64
    let weakImageAlive: Bool, controllerMatches: Bool, primaryMatches: Bool, comparisonMatches: Bool
    let providerCallbackCount: Int, providerCallbackNS: UInt64?, providerCloseSucceeded: Bool?
    let ledger: PreviewPresentationLedger.QATicketState
    var imageRegistered = true
    var managedUnlockCount = 0
    var managedUnlockNS: UInt64?
    var managedUnlockAttempted: Bool?
    var managedUnlockStatus: Int32?
    var managedStorageReleaseCount = 0
    var managedStorageReleaseNS: UInt64?
    var canvasDetachCount = 0
    var canvasDetachNS: UInt64?
    var canvasFieldsCleared: Bool?
  }
  struct Record: Encodable, Sendable {
    let event = "qa022.main-owner"
    let phase: String, atNS: UInt64
    let registryOverflow: Bool
    let registeredCount: Int
    let ticketID: UUID?, bytes: Int?, closeSucceeded: Bool?
    let ledger: PreviewPresentationLedger.QATicketState?
    let images: [ImageState]
    var attributionKnown: Bool?
    var unlockAttempted: Bool?
    var unlockStatus: Int32?
    var canvasID: UUID?
    var frameID: UUID?
    var canvasFieldsCleared: Bool?
    // Weak identity, callback metadata and the ledger are separate synchronized reads.
    let atomicSnapshot = false
  }
  final class Store: @unchecked Sendable {
    private final class WeakImage {
      weak var value: NSImage?
      init(_ image: NSImage) { value = image }
    }
    private struct Entry {
      var image: WeakImage?
      let bytes: Int
      var imageRegistered = false
      var managedUnlockCount = 0
      var managedUnlockNS: UInt64?
      var managedUnlockAttempted: Bool?
      var managedUnlockStatus: Int32?
      var managedStorageReleaseCount = 0
      var managedStorageReleaseNS: UInt64?
      var canvasDetachCount = 0
      var canvasDetachNS: UInt64?
      var canvasFieldsCleared: Bool?
      var callbackCount = 0
      var callbackNS: UInt64?
      var closeSucceeded: Bool?
    }
    private let lock = NSLock()
    private let ledger: PreviewPresentationLedger
    private var entries: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var overflow = false
    init(ledger: PreviewPresentationLedger) { self.ledger = ledger }

    func contains(_ id: UUID) -> Bool {
      lock.lock(); defer { lock.unlock() }; return entries[id]?.imageRegistered == true
    }
    func register(image: NSImage, ticketID: UUID, bytes: Int) -> Record? {
      lock.lock()
      guard entries[ticketID]?.imageRegistered != true else { lock.unlock(); return nil }
      if entries[ticketID] == nil && order.count == 32 {
        guard !overflow else { lock.unlock(); return nil }
        overflow = true; let count = entries.values.filter { $0.imageRegistered }.count; lock.unlock()
        return Record(phase: "registry-overflow", atNS: DispatchTime.now().uptimeNanoseconds,
          registryOverflow: true, registeredCount: count, ticketID: nil, bytes: nil,
          closeSucceeded: nil, ledger: nil, images: [])
      }
      var entry = entries[ticketID] ?? Entry(bytes: bytes)
      if entries[ticketID] == nil { order.append(ticketID) }
      entry.image = WeakImage(image); entry.imageRegistered = true; entries[ticketID] = entry
      let count = entries.values.filter { $0.imageRegistered }.count, wasOverflow = overflow; lock.unlock()
      return Record(phase: "registered", atNS: DispatchTime.now().uptimeNanoseconds,
        registryOverflow: wasOverflow, registeredCount: count, ticketID: ticketID, bytes: bytes,
        closeSucceeded: nil, ledger: ledger.qaTicketState(ticketID), images: [])
    }
    func providerReleased(ticketID: UUID, closeSucceeded: Bool) -> Record? {
      let now = DispatchTime.now().uptimeNanoseconds
      lock.lock()
      guard var entry = entries[ticketID], entry.imageRegistered else { lock.unlock(); return nil }
      entry.callbackCount += 1; entry.callbackNS = now; entry.closeSucceeded = closeSucceeded
      entries[ticketID] = entry
      let count = entries.values.filter { $0.imageRegistered }.count, wasOverflow = overflow; lock.unlock()
      return Record(phase: "provider-release-returned", atNS: now, registryOverflow: wasOverflow,
        registeredCount: count, ticketID: ticketID, bytes: entry.bytes, closeSucceeded: closeSucceeded,
        ledger: ledger.qaTicketState(ticketID), images: [])
    }
    /// Unknown early events retain scalar order within the same 32-entry bound. A
    /// pending scalar is not an image registration and cannot authorize a frame ID.
    private func managedEvent(ticketID: UUID, bytes: Int, unlock: Bool, attempted: Bool?, status: Int32?) -> Record {
      let now = DispatchTime.now().uptimeNanoseconds
      lock.lock()
      var entry = entries[ticketID] ?? Entry(bytes: bytes)
      let known = entry.imageRegistered
      if unlock {
        entry.managedUnlockCount += 1; entry.managedUnlockNS = now
        entry.managedUnlockAttempted = attempted; entry.managedUnlockStatus = status
      } else {
        entry.managedStorageReleaseCount += 1; entry.managedStorageReleaseNS = now
      }
      if entries[ticketID] != nil || order.count < 32 {
        if entries[ticketID] == nil { order.append(ticketID) }
        entries[ticketID] = entry
      } else { overflow = true }
      let count = entries.values.filter { $0.imageRegistered }.count, wasOverflow = overflow; lock.unlock()
      // Never load weak images or query the ledger under the Store lock.
      return Record(phase: unlock ? "managed-provider-unlock-completed" : "managed-storage-release-returned",
        atNS: now, registryOverflow: wasOverflow, registeredCount: count, ticketID: ticketID, bytes: bytes,
        closeSucceeded: nil, ledger: ledger.qaTicketState(ticketID), images: [], attributionKnown: known,
        unlockAttempted: attempted, unlockStatus: status)
    }
    func managedUnlocked(ticketID: UUID, bytes: Int, attempted: Bool, status: Int32?) -> Record {
      managedEvent(ticketID: ticketID, bytes: bytes, unlock: true, attempted: attempted, status: status)
    }
    func managedStorageReleased(ticketID: UUID, bytes: Int) -> Record {
      managedEvent(ticketID: ticketID, bytes: bytes, unlock: false, attempted: nil, status: nil)
    }
    @MainActor func ticketID(for image: NSImage?) -> UUID? {
      guard let image else { return nil }
      lock.lock()
      let copy = order.compactMap { id in entries[id].flatMap { $0.imageRegistered ? (id, $0.image) : nil } }
      lock.unlock()
      for (id, box) in copy { if let existing = box?.value, existing === image { return id } }
      return nil
    }
    @MainActor func canvasCleared(canvasID: UUID?, frameID: UUID?, ticketID: UUID?, fieldsCleared: Bool) -> Record {
      let now = DispatchTime.now().uptimeNanoseconds
      lock.lock()
      let known = ticketID.flatMap { entries[$0]?.imageRegistered } == true
      if let ticketID, var entry = entries[ticketID] {
        entry.canvasDetachCount += 1; entry.canvasDetachNS = now; entry.canvasFieldsCleared = fieldsCleared
        entries[ticketID] = entry
      }
      lock.unlock()
      let record = snapshot("canvas-detach-cleared", controller: nil, primary: nil, comparison: nil)
      // The scalar association is explicit even if no registered image is available.
      return Record(phase: record.phase, atNS: now, registryOverflow: record.registryOverflow,
        registeredCount: record.registeredCount, ticketID: ticketID, bytes: ticketID.flatMap { id in record.images.first { $0.ticketID == id }?.bytes },
        closeSucceeded: nil, ledger: ticketID.map { ledger.qaTicketState($0) }, images: record.images,
        attributionKnown: known, canvasID: canvasID, frameID: frameID, canvasFieldsCleared: fieldsCleared)
    }
    @MainActor func snapshot(_ stage: String, controller: NSImage?, primary: NSImage?, comparison: NSImage?) -> Record {
      // Copy weak boxes and scalars under lock, never load an NSImage there. Dropping
      // a temporary strong image can synchronously call the provider and reenter Store.
      lock.lock()
      let copy = order.compactMap { id in entries[id].map { (id, $0) } }
      let wasOverflow = overflow; lock.unlock()
      let images = copy.map { id, entry -> ImageState in
        let began = DispatchTime.now().uptimeNanoseconds
        let identity = Self.identity(entry.image, controller: controller, primary: primary, comparison: comparison)
        return ImageState(ticketID: id, bytes: entry.bytes, sampleBeganNS: began,
          sampledNS: DispatchTime.now().uptimeNanoseconds, weakImageAlive: identity.0,
          controllerMatches: identity.1, primaryMatches: identity.2, comparisonMatches: identity.3,
          providerCallbackCount: entry.callbackCount, providerCallbackNS: entry.callbackNS,
          providerCloseSucceeded: entry.closeSucceeded, ledger: ledger.qaTicketState(id),
          imageRegistered: entry.imageRegistered, managedUnlockCount: entry.managedUnlockCount,
          managedUnlockNS: entry.managedUnlockNS, managedUnlockAttempted: entry.managedUnlockAttempted,
          managedUnlockStatus: entry.managedUnlockStatus, managedStorageReleaseCount: entry.managedStorageReleaseCount,
          managedStorageReleaseNS: entry.managedStorageReleaseNS, canvasDetachCount: entry.canvasDetachCount,
          canvasDetachNS: entry.canvasDetachNS, canvasFieldsCleared: entry.canvasFieldsCleared)
      }
      return Record(phase: stage, atNS: DispatchTime.now().uptimeNanoseconds,
        registryOverflow: wasOverflow, registeredCount: copy.filter { $0.1.imageRegistered }.count, ticketID: nil,
        bytes: nil, closeSucceeded: nil, ledger: nil, images: images)
    }
    @MainActor private static func identity(_ box: WeakImage?, controller: NSImage?, primary: NSImage?, comparison: NSImage?) -> (Bool, Bool, Bool, Bool) {
      guard let image = box?.value else { return (false, false, false, false) }
      return (true, image === controller, image === primary, image === comparison)
    }
  }
}
