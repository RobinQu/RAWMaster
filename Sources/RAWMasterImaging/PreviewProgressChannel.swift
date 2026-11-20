import Foundation

public enum PreviewDeliveryPolicy: String, Sendable { case latestOnly, inFlightProgress }
public struct PreviewSubmissionID: Hashable, Sendable { public let rawValue: UUID }
public struct PreviewProgressChannelID: Hashable, Sendable { public let rawValue: UUID }
public struct PreviewSubmittedWork: Sendable {
  public let id: PreviewSubmissionID
  public let request: DevelopmentPreviewRequest
}
public struct PreviewCompletedWork: @unchecked Sendable {
  public let work: PreviewSubmittedWork
  public let frame: DevelopmentPreviewFrame
}
public enum PreviewSubmissionOutcome: String, Sendable { case completed, superseded, cancelled, failed }
public struct PreviewSubmissionTerminal: Sendable {
  public let sequence: UInt64
  public let work: PreviewSubmittedWork
  public let outcome: PreviewSubmissionOutcome
  public let failure: DevelopmentPreviewError?
  public let message: String?
  public let frameID: UUID?
}
public enum PreviewProgressChannelState: String, Sendable { case open, sourceInvalidated, closing, closed }
public struct PreviewDeliverySnapshot: @unchecked Sendable {
  public let sequence: UInt64
  public let channelID: PreviewProgressChannelID
  public let sessionID: DevelopmentPreviewSessionID
  public let sourceGeneration: UInt64
  public let consumerID: PreviewConsumerID
  public let state: PreviewProgressChannelState
  public let active: PreviewSubmittedWork?
  public let pending: PreviewSubmittedWork?
  public let latestCompleted: PreviewCompletedWork?
  public let latestTarget: PreviewSubmittedWork?
  public let latestTargetTerminal: PreviewSubmissionTerminal?
  public let terminals: [PreviewSubmissionTerminal]
  public let terminalOverflowCount: UInt64
}
public enum PreviewEnqueueDisposition: String, Sendable { case buffered, replacedBeforeAdmission }
public struct PreviewEnqueueReceipt: Sendable {
  public let disposition: PreviewEnqueueDisposition
  public let work: PreviewSubmittedWork
  public let replacedBeforeAdmission: PreviewSubmittedWork?
}
public struct PreviewProgressChannel: Sendable {
  public let id: PreviewProgressChannelID
  public let snapshots: AsyncStream<PreviewDeliverySnapshot>
  private let mailbox: PreviewProgressMailbox
  init(mailbox: PreviewProgressMailbox) { self.mailbox = mailbox; id = mailbox.id; snapshots = mailbox.stream }
  /// Buffers a latest intent synchronously. This receipt does not imply native admission.
  public func submit(_ request: DevelopmentPreviewRequest) throws -> PreviewEnqueueReceipt { try mailbox.submit(request) }
  public func noteActivity() { mailbox.noteActivity() }
}

/// One lock protects the synchronous producer mailbox and conflated, sticky delivery state.
/// No per-input render Tasks or image-bearing terminal history are allocated.
final class PreviewProgressMailbox: @unchecked Sendable {
  let id = PreviewProgressChannelID(rawValue: UUID())
  let sessionID: DevelopmentPreviewSessionID
  let generation: UInt64
  let consumerID: PreviewConsumerID
  let stream: AsyncStream<PreviewDeliverySnapshot>
  private let continuation: AsyncStream<PreviewDeliverySnapshot>.Continuation
  private let lock = NSLock()
  private let now: @Sendable () -> UInt64
  private let wake: @Sendable (PreviewProgressChannelID) -> Void
  private var state: PreviewProgressChannelState = .open
  private var inbox: PreviewSubmittedWork?
  private var driving = false
  private var activity: UInt64 = 0
  private var active: PreviewSubmittedWork?
  private var pending: PreviewSubmittedWork?
  private var target: PreviewSubmittedWork?
  private var targetTerminal: PreviewSubmissionTerminal?
  private var completed: PreviewCompletedWork?
  private var terminals: [PreviewSubmissionTerminal] = []
  private var overflow: UInt64 = 0
  private var sequence: UInt64 = 0
  init(sessionID: DevelopmentPreviewSessionID, generation: UInt64, consumerID: PreviewConsumerID,
       now: @escaping @Sendable () -> UInt64, wake: @escaping @Sendable (PreviewProgressChannelID) -> Void,
       terminate: @escaping @Sendable (PreviewProgressChannelID) -> Void) {
    self.sessionID = sessionID; self.generation = generation; self.consumerID = consumerID
    self.now = now; self.wake = wake
    let pair = AsyncStream<PreviewDeliverySnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
    stream = pair.stream; continuation = pair.continuation
    let channelID = id
    continuation.onTermination = { _ in terminate(channelID) }
    emitLocked()
  }
  func submit(_ request: DevelopmentPreviewRequest) throws -> PreviewEnqueueReceipt {
    try request.recipe.validate()
    guard request.sessionID == sessionID, request.sourceGeneration == generation,
      request.consumerID == consumerID, request.role == .primary, request.quality != .detail,
      (1...4096).contains(request.viewport.maxPixel), request.deliveryPolicy == .inFlightProgress,
      (request.clientCorrelation?.count ?? 0) <= 4096 else { throw DevelopmentPreviewError.invalidRequest }
    lock.lock()
    guard state == .open else { lock.unlock(); throw DevelopmentPreviewError.closed }
    // A channel revision identifies a distinct intent, including a settled quality transition.
    guard target == nil || request.revision > target!.request.revision else { lock.unlock(); throw DevelopmentPreviewError.superseded }
    let work = PreviewSubmittedWork(id: .init(rawValue: UUID()), request: request), replaced = inbox
    inbox = work; target = work; targetTerminal = nil
    if request.quality == .interactive { activity = now() }
    if let replaced { terminalLocked(replaced, outcome: .superseded, failure: .superseded) }
    let start = !driving; driving = true; emitLocked(); lock.unlock()
    if start { wake(id) }
    return .init(disposition: replaced == nil ? .buffered : .replacedBeforeAdmission, work: work, replacedBeforeAdmission: replaced)
  }
  func noteActivity() {
    lock.lock(); guard state == .open else { lock.unlock(); return }
    activity = now(); let start = !driving; driving = true; lock.unlock()
    if start { wake(id) }
  }
  var activityAt: UInt64 { lock.lock(); defer { lock.unlock() }; return state == .open ? activity : 0 }
  var latestRevision: UInt64? { lock.lock(); defer { lock.unlock() }; return target?.request.revision }
  func peek() -> PreviewSubmittedWork? { lock.lock(); defer { lock.unlock() }; return state == .open ? inbox : nil }
  func take(_ token: PreviewSubmissionID) -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard state == .open, inbox?.id == token else { return false }; inbox = nil; return true
  }
  /// Returns true only when no input arrived during the driver's final check.
  func stopDriverIfEmpty() -> Bool {
    lock.lock(); defer { lock.unlock() }
    guard inbox == nil || state != .open else { return false }; driving = false; return true
  }
  func update(active: PreviewSubmittedWork?, pending: PreviewSubmittedWork?) {
    lock.lock(); defer { lock.unlock() }; guard state == .open else { return }
    self.active = active; self.pending = pending; emitLocked()
  }
  func complete(_ work: PreviewSubmittedWork, result: Result<DevelopmentPreviewFrame, Error>, cancellation: Bool = false) {
    lock.lock(); defer { lock.unlock() }; guard state == .open else { return }
    switch result {
    case .success(let frame):
      if completed == nil || work.request.revision > completed!.work.request.revision { completed = .init(work: work, frame: frame) }
      terminalLocked(work, outcome: .completed, frameID: frame.frameID)
    case .failure(let error):
      let failure = error as? DevelopmentPreviewError ?? .invalidRequest
      let outcome: PreviewSubmissionOutcome = cancellation ? .cancelled : (failure == .superseded ? .superseded : .failed)
      terminalLocked(work, outcome: outcome, failure: failure, message: boundedMessage(error))
    }
    emitLocked()
  }
  func cancelBuffered() {
    lock.lock(); defer { lock.unlock() }
    guard state == .open else { return }
    if let work = inbox { terminalLocked(work, outcome: .cancelled, failure: .superseded) }
    inbox = nil; emitLocked()
  }
  func revoke(_ next: PreviewProgressChannelState) {
    lock.lock(); defer { lock.unlock() }
    guard state != .closed, state != .closing || next == .closed else { return }
    state = next; inbox = nil; target = nil; targetTerminal = nil; completed = nil; active = nil; pending = nil
    emitLocked()
    if next == .closed { continuation.finish() }
  }
  private func boundedMessage(_ error: Error) -> String {
    var message = String(decoding: Array(String(describing: error).utf8.prefix(1024)), as: UTF8.self)
    while message.utf8.count > 1024 { message.removeLast() }
    return message
  }
  private func terminalLocked(_ work: PreviewSubmittedWork, outcome: PreviewSubmissionOutcome,
                              failure: DevelopmentPreviewError? = nil, message: String? = nil, frameID: UUID? = nil) {
    sequence &+= 1
    let terminal = PreviewSubmissionTerminal(sequence: sequence, work: work, outcome: outcome, failure: failure, message: message, frameID: frameID)
    if terminals.count == 64 { terminals.removeFirst(); overflow &+= 1 }
    terminals.append(terminal)
    if target?.id == work.id { targetTerminal = terminal }
  }
  private func emitLocked() {
    sequence &+= 1
    continuation.yield(.init(sequence: sequence, channelID: id, sessionID: sessionID, sourceGeneration: generation,
      consumerID: consumerID, state: state, active: active, pending: pending, latestCompleted: completed,
      latestTarget: target, latestTargetTerminal: targetTerminal, terminals: terminals, terminalOverflowCount: overflow))
  }
}
