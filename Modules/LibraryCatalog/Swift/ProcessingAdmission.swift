import Foundation

/// Admission applies to physical work on this host, across all documents and windows.
public actor ProcessingAdmission {
    public enum Lane: Sendable { case editing, export, library }

    public struct Resources: Sendable, Equatable {
        public let cpu: Int
        public let gpu: Int
        public let io: Int
        public let memoryBytes: Int

        public init(cpu: Int = 0, gpu: Int = 0, io: Int = 0, memoryBytes: Int = 0) {
            self.cpu = cpu
            self.gpu = gpu
            self.io = io
            self.memoryBytes = memoryBytes
        }

        fileprivate func fits(_ free: Self) -> Bool {
            cpu <= free.cpu && gpu <= free.gpu && io <= free.io && memoryBytes <= free.memoryBytes
        }

        fileprivate func adding(_ request: Self, times sign: Int) -> Self {
            .init(cpu: cpu + sign * request.cpu, gpu: gpu + sign * request.gpu,
                  io: io + sign * request.io, memoryBytes: memoryBytes + sign * request.memoryBytes)
        }
    }

    private struct Waiter {
        let id: UUID
        let lane: Lane
        let demand: Resources
        let presentation: Bool
        var bypasses = 0
        let continuation: CheckedContinuation<Void, Error>
    }

    public static let shared = ProcessingAdmission()
    private static let slots: [Lane] = [.editing, .export, .editing, .library, .editing]
    public nonisolated let capacity: Resources
    private let backgroundGPUCapacity: Int
    private var backgroundGPU = 0
    private var free: Resources
    private var waiters: [Waiter] = []
    private var slot = 0

    public init(capacity: Resources? = nil) {
        let host = ProcessInfo.processInfo
        let gpuSlots = host.activeProcessorCount >= 8 && host.physicalMemory >= 32 << 30 ? 4 : 2
        let budget = capacity ?? .init(cpu: max(1, min(8, host.activeProcessorCount - 1)),
                                       gpu: gpuSlots, io: 3, memoryBytes: Int(host.physicalMemory / 3))
        self.capacity = budget
        backgroundGPUCapacity = budget.gpu >= 2 ? budget.gpu - 1 : budget.gpu
        free = budget
    }

    /// The operation must join its native work (including GPU completion) before returning.
    /// Cancellation removes a waiter immediately. Admitted work holds its reservations until it actually returns.
    /// One GPU submission slot is reserved for the editing preview while background work runs.
    public nonisolated func withPermit<T: Sendable>(_ lane: Lane, resources: Resources, presentation: Bool = false,
        operation: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await acquire(id, lane, resources, presentation)
        } onCancel: {
            Task { await self.cancelWaiting(id) }
        }
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await release(resources, presentation)
            return result
        } catch {
            await release(resources, presentation)
            throw error
        }
    }

    private func acquire(_ id: UUID, _ lane: Lane, _ demand: Resources, _ presentation: Bool) async throws {
        try Task.checkCancellation()
        guard demand != .init(), min(demand.cpu, demand.gpu, demand.io, demand.memoryBytes) >= 0,
              demand.fits(capacity), presentation ? (lane == .editing && demand.gpu > 0) : demand.gpu <= backgroundGPUCapacity else {
            throw LibraryEngineError("处理阶段的资源需求超过本机可用额度。")
        }
        try await withCheckedThrowingContinuation { continuation in
            waiters.append(.init(id: id, lane: lane, demand: demand, presentation: presentation, continuation: continuation))
            drain()
        }
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        drain()
    }

    private func release(_ resources: Resources, _ presentation: Bool) {
        if !presentation { backgroundGPU -= resources.gpu }
        free = free.adding(resources, times: 1)
        drain()
    }

    private func fits(_ waiter: Waiter) -> Bool {
        waiter.demand.fits(free) && (waiter.presentation || backgroundGPU + waiter.demand.gpu <= backgroundGPUCapacity)
    }

    private func drain() {
        while !waiters.isEmpty {
            // Give an old large request a chance to accumulate all the permits it needs.
            let aged = waiters.firstIndex { $0.bypasses >= 8 }
            let interactive = waiters.firstIndex { $0.presentation && fits($0) }
            let activePresentationGPU = capacity.gpu - free.gpu - backgroundGPU
            // The oldest background waiter cannot reserve the preview's slot while a long GPU command runs.
            let allowPreview = activePresentationGPU == 0 || aged.map { !fits(waiters[$0]) } == true
            let reserved = (allowPreview ? interactive : nil) ?? aged
            if let reserved, !fits(waiters[reserved]) { return }
            var selected: (index: Int, slot: Int)?
            for offset in Self.slots.indices {
                let next = (slot + offset) % Self.slots.count
                if let reserved {
                    if waiters[reserved].lane == Self.slots[next] { selected = (reserved, next) }
                } else if let index = waiters.firstIndex(where: { $0.lane == Self.slots[next] && fits($0) }) {
                    selected = (index, next)
                }
                if selected != nil { break }
            }
            guard let selected else { return }
            for i in 0..<selected.index { waiters[i].bypasses += 1 }
            let admitted = waiters.remove(at: selected.index)
            slot = (selected.slot + 1) % Self.slots.count
            if !admitted.presentation { backgroundGPU += admitted.demand.gpu }
            free = free.adding(admitted.demand, times: -1)
            admitted.continuation.resume()
        }
    }
}
