import Foundation

/// Presentation failures never escape as RawBaseCacheError.capacity: that would
/// admit an unintended second RAW pipeline from the outer raw-base fallback.
enum PreviewPresentationError: Error, Equatable {
  case displayCapacity, allocationProtocol, closed, unsupported, invalidLayout
  case gpuFailed, cpuLockFailed, imageCreationFailed
}

struct PreviewPresentationStatistics: Sendable {
  var reservedCPUBytes = 0, allocatedCPUBytes = 0, retiredCPUBytes = 0
  var reservedGPUBytes = 0, allocatedGPUBytes = 0, retiredGPUBytes = 0
  var allocations = 0
  var cleanupFailures: UInt64 = 0
  var admissionClosed = false
  var chargedCPUBytes: Int { reservedCPUBytes + allocatedCPUBytes }
  var chargedGPUBytes: Int { reservedGPUBytes + allocatedGPUBytes }
}

/// Opt-in only. One ledger spans both panes and CPU fallbacks; not one per frame.
/// CPU contains every shared allocation AND CPU-only fallback. GPU is a subset,
/// so adding chargedCPUBytes+chargedGPUBytes would double-count shared storage.
final class PreviewPresentationLedger: @unchecked Sendable {
  enum Kind { case sharedSurface, cpuFallback }
  private struct Entry {
    let kind: Kind
    let reservation: Int
    let scopeID: UUID?
    var actual: Int?
    var retired = false
  }
  private let lock = NSLock()
  private let cpuBudget: Int, gpuBudget: Int
  private var entries: [UUID: Entry] = [:]
  private var closed = false
  private var cleanupFailures: UInt64 = 0
  private let optionalNeuralInputs = NSHashTable<PreviewInteractiveProxyPool>.weakObjects()

  func registerOptionalNeuralInputs(_ pool: PreviewInteractiveProxyPool) {
    lock.lock(); optionalNeuralInputs.add(pool); lock.unlock()
  }

  /// Cached extra neural inputs share this ledger across panes and services. Take owners
  /// out of the lock before asking them to retire their storage and release reservations.
  private func admit<T>(_ reservation: () throws -> T) throws -> T {
    do { return try reservation() } catch PreviewPresentationError.displayCapacity {
      lock.lock(); let owners = optionalNeuralInputs.allObjects; lock.unlock()
      var reclaimed = false
      for owner in owners where owner.reclaimSpareNeuralInput() { reclaimed = true }
      guard reclaimed else { throw PreviewPresentationError.displayCapacity }
      return try reservation()
    }
  }
  /// A single physical budget for every opted-in pane, service and retained image.
  /// Closing an individual scope never shuts admission for unrelated scopes.
  static let shared = PreviewPresentationLedger()
  init(cpuBudget: Int = 268_435_456, gpuBudget: Int = 201_326_592) {
    self.cpuBudget = max(0, min(268_435_456, cpuBudget))
    // Two 2400px RGBA32F proxies plus the compact display output fit this shared cap.
    self.gpuBudget = max(0, min(201_326_592, gpuBudget))
  }
  func reserveSharedSurface(bytes: Int) throws -> PreviewPresentationReservation {
    try reserve(bytes: bytes, kind: .sharedSurface, scopeID: nil)
  }
  /// The future same-graph fallback must hold this ticket for its entire buffer
  /// lifetime. GPU exhaustion is never permission for uncharged CPU allocation.
  func reserveCPUFallback(bytes: Int) throws -> PreviewPresentationReservation {
    try reserve(bytes: bytes, kind: .cpuFallback, scopeID: nil)
  }
  fileprivate func reserve(bytes: Int, kind: Kind, scopeID: UUID?) throws -> PreviewPresentationReservation {
    try admit { try recordReservation(bytes: bytes, kind: kind, scopeID: scopeID) }
  }
  private func recordReservation(bytes: Int, kind: Kind, scopeID: UUID?) throws -> PreviewPresentationReservation {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { throw PreviewPresentationError.closed }
    guard bytes > 0 else { throw PreviewPresentationError.invalidLayout }
    let current = snapshotLocked()
    guard bytes <= cpuBudget, current.chargedCPUBytes <= cpuBudget - bytes else { throw PreviewPresentationError.displayCapacity }
    if kind == .sharedSurface {
      guard bytes <= gpuBudget, current.chargedGPUBytes <= gpuBudget - bytes else { throw PreviewPresentationError.displayCapacity }
    }
    let id = UUID(); entries[id] = Entry(kind: kind, reservation: bytes, scopeID: scopeID)
    return PreviewPresentationReservation(id: id, ledger: self)
  }
  /// Atomic known-peak reservation for one I1 operation. Shared aliases count once in CPU
  /// and once in the GPU subset, never as an extra independent pool per proxy/output.
  fileprivate func reserveSharedOperation(bytes:[Int],scopeID:UUID)throws->[PreviewPresentationReservation] {
    try admit { try recordSharedOperation(bytes: bytes, scopeID: scopeID) }
  }
  private func recordSharedOperation(bytes:[Int],scopeID:UUID)throws->[PreviewPresentationReservation] {
    lock.lock();defer{lock.unlock()}
    guard !closed else{throw PreviewPresentationError.closed}
    guard !bytes.isEmpty,bytes.allSatisfy({$0>0}) else{throw PreviewPresentationError.invalidLayout}
    var total=0
    for b in bytes{let(n,overflow)=total.addingReportingOverflow(b);guard !overflow else{throw PreviewPresentationError.displayCapacity};total=n}
    let current=snapshotLocked()
    guard total<=cpuBudget,total<=gpuBudget,current.chargedCPUBytes<=cpuBudget-total,
      current.chargedGPUBytes<=gpuBudget-total else{throw PreviewPresentationError.displayCapacity}
    return bytes.map{b in let id=UUID();entries[id]=Entry(kind:.sharedSurface,reservation:b,scopeID:scopeID);return PreviewPresentationReservation(id:id,ledger:self)}
  }
  fileprivate func retireEntry(_ id:UUID){lock.lock();entries[id]?.retired=true;lock.unlock()}
  fileprivate func allocated(_ id: UUID, actual: Int) throws {
    lock.lock(); defer { lock.unlock() }
    guard var entry = entries[id], entry.actual == nil, actual > 0 else { throw PreviewPresentationError.allocationProtocol }
    // Account the real physical allocation BEFORE throwing a mismatch/closed
    // error. The owner must release it before releasing the reservation ticket.
    entry.actual = actual; entries[id] = entry
    let current = snapshotLocked()
    guard actual <= entry.reservation, current.chargedCPUBytes <= cpuBudget,
          current.chargedGPUBytes <= gpuBudget else { throw PreviewPresentationError.allocationProtocol }
    guard !closed, !entry.retired else { throw PreviewPresentationError.closed }
  }
  fileprivate func requireOpen(_ id: UUID) throws {
    lock.lock(); defer { lock.unlock() }
    guard !closed, let entry = entries[id], !entry.retired else { throw PreviewPresentationError.closed }
  }
  fileprivate func release(_ id: UUID) {
    lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: id)
  }
  fileprivate func recordCleanupFailure() {
    lock.lock(); cleanupFailures &+= 1; lock.unlock()
  }
  /// Does not join a GPU task or invalidate previously published image bytes.
  /// Caller still joins its task. Retained providers remain retired and charged.
  func closeAdmissionAndRetire() -> PreviewPresentationStatistics {
    lock.lock(); defer { lock.unlock() }; closed = true
    for id in Array(entries.keys) { entries[id]?.retired = true }
    return snapshotLocked()
  }
  fileprivate func retire(scopeID: UUID) {
    lock.lock(); defer { lock.unlock() }
    for id in Array(entries.keys) where entries[id]?.scopeID == scopeID { entries[id]?.retired = true }
  }
  var statistics: PreviewPresentationStatistics {
    lock.lock(); defer { lock.unlock() }; return snapshotLocked()
  }
  struct QATicketState: Encodable, Sendable {
    let present: Bool
    let reservedBytes: Int?, allocatedBytes: Int?, retired: Bool?, sharedSurface: Bool?
  }
  /// Read-only ticket lookup; absence does not manufacture a release event.
  func qaTicketState(_ id: UUID) -> QATicketState {
    lock.lock(); defer { lock.unlock() }
    guard let entry = entries[id] else {
      return .init(present: false, reservedBytes: nil, allocatedBytes: nil, retired: nil, sharedSurface: nil)
    }
    return .init(present: true, reservedBytes: entry.reservation, allocatedBytes: entry.actual,
      retired: entry.retired, sharedSurface: entry.kind == .sharedSurface)
  }
  private func snapshotLocked() -> PreviewPresentationStatistics {
    var value = PreviewPresentationStatistics(); value.admissionClosed = closed; value.cleanupFailures = cleanupFailures
    for entry in entries.values {
      let bytes = entry.actual ?? entry.reservation
      if entry.actual == nil { value.reservedCPUBytes += bytes }
      else { value.allocatedCPUBytes += bytes; value.allocations += 1 }
      if entry.retired { value.retiredCPUBytes += bytes }
      if entry.kind == .sharedSurface {
        if entry.actual == nil { value.reservedGPUBytes += bytes }
        else { value.allocatedGPUBytes += bytes }
        if entry.retired { value.retiredGPUBytes += bytes }
      }
    }
    return value
  }
}

/// Source-only opt-in handle. Product handles always use the shared global ledger;
/// an explicitly injected ledger is for isolated tests. A scope is a publication
/// admission fence, not ownership of the images it has already returned.
final class PreviewPresentationScope: @unchecked Sendable {
  let id = UUID()
  let ledger: PreviewPresentationLedger
  private let lock = NSLock()
  private var closed = false
  init() { ledger = .shared }
  init(ledgerForTesting ledger: PreviewPresentationLedger) { self.ledger = ledger }
  func reserveSharedSurface(bytes: Int) throws -> PreviewPresentationReservation {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { throw PreviewPresentationError.closed }
    return try ledger.reserve(bytes: bytes, kind: .sharedSurface, scopeID: id)
  }
  func reserveCPUFallback(bytes: Int) throws -> PreviewPresentationReservation {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { throw PreviewPresentationError.closed }
    return try ledger.reserve(bytes: bytes, kind: .cpuFallback, scopeID: id)
  }
  func reserveSharedOperation(bytes:[Int])throws->[PreviewPresentationReservation] {
    lock.lock();defer{lock.unlock()};guard !closed else{throw PreviewPresentationError.closed}
    return try ledger.reserveSharedOperation(bytes:bytes,scopeID:id)
  }
  func requireOpenAdmission() throws {
    lock.lock(); defer { lock.unlock() }
    guard !closed, !ledger.statistics.admissionClosed else { throw PreviewPresentationError.closed }
  }
  /// Native callers still join their producer before acknowledging their worker
  /// close. This only retires this scope; providers stay valid and fully charged.
  func closeAndRetire() {
    lock.lock(); defer { lock.unlock() }
    guard !closed else { return }; closed = true; ledger.retire(scopeID: id)
  }
  func retireOutstanding(){ledger.retire(scopeID:id)}
  deinit { closeAndRetire() }
}

final class PreviewPresentationReservation: @unchecked Sendable {
  let id: UUID
  private let ledger: PreviewPresentationLedger
  private let lock = NSLock()
  private var released = false
  fileprivate init(id: UUID, ledger: PreviewPresentationLedger) { self.id = id; self.ledger = ledger }
  func registerActualAllocation(bytes: Int) throws {
    lock.lock(); defer { lock.unlock() }
    guard !released else { throw PreviewPresentationError.closed }
    try ledger.allocated(id, actual: bytes)
  }
  func requireOpenAdmission() throws {
    lock.lock(); defer { lock.unlock() }
    guard !released else { throw PreviewPresentationError.closed }; try ledger.requireOpen(id)
  }
  func markRetired(){ledger.retireEntry(id)}
  func recordCleanupFailure() { ledger.recordCleanupFailure() }
  /// Owner clears all real storage/views FIRST. Retained released tickets do not
  /// retain storage and multiple callbacks cannot subtract twice.
  func releaseAfterStorageReleased() {
    lock.lock(); defer { lock.unlock() }
    guard !released else { return }; released = true; ledger.release(id)
  }
  deinit { releaseAfterStorageReleased() }
}
