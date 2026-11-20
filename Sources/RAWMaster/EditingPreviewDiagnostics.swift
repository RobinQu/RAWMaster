import AppKit
import RAWMasterImaging

/// Classification is independent of event age: queued native actions must not disappear from the slow tail.
struct EditingPreviewInput: Codable, Sendable {
    enum Origin: String, Codable, Sendable { case programmatic, nativeAction = "native-action", unattributed }
    enum Association: String, Codable, Sendable {
        case programmatic, direct, aged, missingEvent = "missing-event", unsupportedEvent = "unsupported-event", futureTimestamp = "future-timestamp", missingCorrelation = "missing-correlation", malformedCorrelation = "malformed-correlation"
    }
    let id: UUID
    let committedAt: UInt64
    let eventAt: UInt64?
    let control: String
    let phase: String
    let origin: Origin
    let association: Association
    let gestureID: UUID?
    let settleTriggeredAt: UInt64?
    let releaseEventAt: UInt64?
    var eventAgeNanoseconds: UInt64? { eventAt.map { committedAt - $0 } }

    /// Pure-clock seam for classification tests; programmatic callers never inherit a supplied event timestamp.
    static func classified(control: String, phase: String, committedAt: UInt64, eventAt: UInt64?,
                           nativeEvent: Bool, relevantEvent: Bool = true, gestureID: UUID? = nil) -> Self {
        let origin: Origin = nativeEvent ? .nativeAction : .programmatic
        let association: Association
        let associated: UInt64?
        if !nativeEvent { association = .programmatic; associated = nil }
        else if !relevantEvent { association = .unsupportedEvent; associated = nil }
        else if let eventAt {
            if eventAt > committedAt { association = .futureTimestamp; associated = nil }
            else { association = committedAt - eventAt > 250_000_000 ? .aged : .direct; associated = eventAt }
        } else { association = .missingEvent; associated = nil }
        return .init(id: UUID(), committedAt: committedAt, eventAt: associated, control: control, phase: phase,
                     origin: origin, association: association, gestureID: gestureID, settleTriggeredAt: nil, releaseEventAt: nil)
    }
    @MainActor static func capture(control: String, phase: String, nativeEvent: Bool = false, gestureID: UUID? = nil) -> Self {
        let committed = DispatchTime.now().uptimeNanoseconds
        guard nativeEvent else {
            return classified(control: control, phase: phase, committedAt: committed, eventAt: nil, nativeEvent: false, gestureID: gestureID)
        }
        let event = NSApp?.currentEvent
        let relevant = event.map { [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .keyDown, .scrollWheel].contains($0.type) } ?? true
        let timestamp = event.flatMap { value -> UInt64? in
            let nanos = value.timestamp * 1_000_000_000
            guard nanos.isFinite, nanos >= 0, nanos < Double(UInt64.max) else { return nil }
            return UInt64(nanos)
        }
        return classified(control: control, phase: phase, committedAt: committed, eventAt: timestamp,
                          nativeEvent: true, relevantEvent: relevant, gestureID: gestureID)
    }
    func correlationData() -> Data? {
        guard let data = try? JSONEncoder().encode(self), data.count <= 4096 else { return nil }
        return data
    }
    static func unattributed(id: UUID, reason: String) -> Self {
        .init(id: id, committedAt: 0, eventAt: nil, control: reason, phase: "unattributed", origin: .unattributed,
              association: reason == "malformed-correlation" ? .malformedCorrelation : .missingCorrelation,
              gestureID: nil, settleTriggeredAt: nil, releaseEventAt: nil)
    }
    static func decodeCorrelation(_ data: Data?, token: UUID) -> Self {
        guard let data else { return .unattributed(id: token, reason: "missing-correlation") }
        guard data.count <= 4096, let input = try? JSONDecoder().decode(Self.self, from: data),
              input.eventAt.map({ $0 <= input.committedAt }) ?? true,
              input.origin != .programmatic || input.eventAt == nil else { return .unattributed(id: token, reason: "malformed-correlation") }
        return input
    }
    func settling(after release: Self) -> Self {
        .init(id: id, committedAt: committedAt, eventAt: eventAt, control: control, phase: "settled",
              origin: origin, association: association, gestureID: gestureID ?? release.gestureID,
              settleTriggeredAt: release.committedAt, releaseEventAt: origin == .nativeAction ? release.eventAt : nil)
    }
}

/// A scalar watermark rejects arbitrarily late duplicate render endings; no per-revision history grows.
/// No-render operations share a revision, so only their recent operation IDs need a small bounded ring.
struct EditingPreviewTerminalLedger {
    private(set) var terminalRevision: UInt64 = 0
    private struct NoRender: Equatable { let operation: UUID; let quality: String; let outcome: String }
    private var noRender: [NoRender] = []
    let capacity: Int
    init(capacity: Int = 64) { self.capacity = max(1, capacity) }
    var retainedOperationCount: Int { noRender.count }
    mutating func acceptRenderedTerminal(revision: UInt64) -> Bool {
        guard revision > terminalRevision else { return false }
        terminalRevision = revision; return true
    }
    mutating func acceptNoRender(operation: UUID, quality: PreviewQuality, outcome: String) -> Bool {
        let key = NoRender(operation: operation, quality: quality.rawValue, outcome: outcome)
        guard !noRender.contains(key) else { return false }
        if noRender.count == capacity { noRender.removeFirst() }
        noRender.append(key); return true
    }
}
struct EditingPreviewDiagnosticEvent {
    let inputOrigin: EditingPreviewInput.Origin
    let association: EditingPreviewInput.Association
    let control: String
    let operationID: UUID
    let pane: PreviewConsumerRole
    let revision: UInt64
    let quality: PreviewQuality
    let outcome: String
    let reason: String
}

/// Progress terminal ordering follows tokens, never request revision. Only bounded scalar metadata is retained.
struct EditingProgressTerminalLedger {
    private var registered: [UUID: Bool] = [:]
    private var completed: [UUID] = []
    let capacity: Int
    init(capacity: Int = 64) { self.capacity = max(1, capacity) }
    var retainedCount: Int { Set(registered.keys).union(completed).count }
    mutating func register(_ active: UUID?, _ pending: UUID?, _ target: UUID?) {
        let ids = Set([active, pending, target].compactMap { $0 })
        registered = Dictionary(uniqueKeysWithValues: ids.map { ($0, registered[$0] ?? completed.contains($0)) })
    }
    mutating func accept(_ token: UUID) -> Bool {
        guard registered[token] != true, !completed.contains(token) else { return false }
        if registered[token] != nil { registered[token] = true }
        if completed.count == capacity { completed.removeFirst() }
        completed.append(token); return true
    }
}
