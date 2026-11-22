import Foundation

public struct MaskJobResult: Sendable {
    public let snapshot: MaskSnapshot
    public let cacheHit: Bool
    public let elapsedMilliseconds: Double
    public let notes: [String]
}

public struct MaskJob: Sendable {
    public let id: UUID
    public let descriptor: SemanticMaskDescriptor
    fileprivate let task: Task<MaskJobResult, Error>

    public func result() async throws -> MaskJobResult { try await task.value }
}

public actor MaskAICoordinator {
    private struct JobState {
        let cancellation: ONNXCancellation
        let task: Task<MaskJobResult, Error>
    }

    private let client: MaskAIClient
    private let store: MaskSnapshotStore
    /// Serializes the non-thread-safe native client while allowing callers to remain async.
    private let executor = DispatchQueue(label: "MaskAI.NativeExecutor")
    private var jobs: [UUID: JobState] = [:]

    public init(client: MaskAIClient, store: MaskSnapshotStore) {
        self.client = client; self.store = store
    }

    public var activeJobCount: Int { jobs.count }

    public func submit(descriptor: SemanticMaskDescriptor, image: NativeImage) throws -> MaskJob {
        try descriptor.validate()
        let id = UUID()
        let cancellation = ONNXCancellation()
        let task = Task.detached { [client, store, executor] in
            let started = Date()
            return try executor.sync {
                try cancellation.throwIfCancelled()
                if let existing = try store.latest(for: descriptor) {
                    return MaskJobResult(snapshot: existing, cacheHit: true,
                                         elapsedMilliseconds: Date().timeIntervalSince(started) * 1000, notes: [])
                }
                let result = try Self.infer(client: client, descriptor: descriptor, image: image, cancellation: cancellation)
                try cancellation.throwIfCancelled()
                var committed: MaskSnapshot?
                do {
                    let snapshot = try store.save(mask: result.mask, descriptor: descriptor)
                    committed = snapshot
                    try cancellation.throwIfCancelled()
                    return MaskJobResult(snapshot: snapshot, cacheHit: false,
                                         elapsedMilliseconds: Date().timeIntervalSince(started) * 1000,
                                         notes: result.metrics.notes)
                } catch {
                    if let committed { try? store.discard(committed) }
                    throw error
                }
            }
        }
        jobs[id] = JobState(cancellation: cancellation, task: task)
        Task { [weak self] in
            _ = try? await task.value
            await self?.finish(id)
        }
        return MaskJob(id: id, descriptor: descriptor, task: task)
    }

    public func cancel(_ job: MaskJob) {
        guard let state = jobs[job.id] else { return }
        state.cancellation.cancel()
        state.task.cancel()
    }

    public func cancelAll() {
        for state in jobs.values {
            state.cancellation.cancel()
            state.task.cancel()
        }
    }

    /// Cancels active work, then waits for the native executor to release sessions and image-derived caches.
    public func releaseResources() async {
        cancelAll()
        _ = await Task.detached { [client, executor] in
            executor.sync { client.releaseResources() }
        }.value
    }

    private func finish(_ id: UUID) {
        jobs.removeValue(forKey: id)
    }

    private static func infer(client: MaskAIClient, descriptor: SemanticMaskDescriptor,
                              image: NativeImage, cancellation: ONNXCancellation) throws -> MaskResult {
        switch descriptor.kind {
        case .subject:
            return try client.subject(in: image, cancellation: cancellation)
        case .background:
            return try client.background(in: image, cancellation: cancellation)
        case .landscape:
            guard let target = LandscapeMaskTarget(rawValue: descriptor.target) else {
                throw MaskAIError.invalidInput("Unknown landscape target \(descriptor.target).")
            }
            return try client.landscape(in: image, target: target, cancellation: cancellation)
        case .object:
            guard let prompt = descriptor.objectPrompt else { throw MaskAIError.invalidInput("Missing object prompt.") }
            return try client.object(in: image, prompt: prompt, cancellation: cancellation)
        case .person:
            guard let target = PersonMaskTarget(rawValue: descriptor.target) else {
                throw MaskAIError.invalidInput("Unknown person target \(descriptor.target).")
            }
            return try client.person(in: image, target: target, personIndex: descriptor.personIndex, cancellation: cancellation)
        }
    }
}
