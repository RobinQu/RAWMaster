import Foundation

/// Bounded synchronous workers for blocking metadata providers. The caller runs off the main actor.
/// The first failure stops admission and cancels siblings; concurrentPerform joins every worker
/// before returning, so child processes and native reads cannot outlive the failed analysis.
enum OrderedMetadataWorkers {
    private final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
        func check() throws {
            lock.lock(); let stopped = cancelled; lock.unlock()
            if stopped { throw CancellationError() }
        }
    }

    /// Task cancellation is explicitly bridged into detached and GCD work, where the
    /// caller's Task.isCancelled is otherwise unavailable. Awaiting value joins the work.
    static func offMain<Output: Sendable>(
        check: @escaping @Sendable () throws -> Void,
        operation: @escaping @Sendable (@escaping @Sendable () throws -> Void) throws -> Output
    ) async throws -> Output {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await Task.detached(priority: .utility) {
                try operation {
                    try cancellation.check()
                    try check()
                }
            }.value
        }, onCancel: { cancellation.cancel() })
    }

    private final class State<Output>: @unchecked Sendable {
        private let lock = NSLock()
        private var next = 0
        private var failure: Error?
        private var results: [Output?]

        init(count: Int) { results = Array(repeating: nil, count: count) }
        func claim() -> Int? {
            lock.lock(); defer { lock.unlock() }
            guard failure == nil, next < results.count else { return nil }
            defer { next += 1 }
            return next
        }
        func check() throws {
            lock.lock(); let stopped = failure != nil; lock.unlock()
            if stopped { throw CancellationError() }
        }
        func finish(_ value: Output, at index: Int) {
            lock.lock(); defer { lock.unlock() }
            results[index] = value
        }
        func fail(_ error: Error) {
            lock.lock(); defer { lock.unlock() }
            if failure == nil { failure = error }
        }
        func collected() throws -> [Output] {
            lock.lock(); defer { lock.unlock() }
            if let failure { throw failure }
            // A worker claims every index exactly once; successful joining fills every slot.
            return results.map { $0! }
        }
    }

    static func map<Input: Sendable, Output: Sendable>(
        _ inputs: [Input], limit: Int,
        check: @escaping @Sendable () throws -> Void,
        transform: @escaping @Sendable (Int, Input, @escaping @Sendable () throws -> Void) throws -> Output
    ) throws -> [Output] {
        try check()
        guard !inputs.isEmpty else { return [] }
        let state = State<Output>(count: inputs.count)
        let checkpoint: @Sendable () throws -> Void = {
            try state.check()
            try check()
        }
        DispatchQueue.concurrentPerform(iterations: min(max(1, limit), inputs.count)) { _ in
            while let index = state.claim() {
                do {
                    try checkpoint()
                    let value = try transform(index, inputs[index], checkpoint)
                    try checkpoint()
                    state.finish(value, at: index)
                } catch {
                    state.fail(error)
                    return
                }
            }
        }
        let values = try state.collected()
        try check()
        return values
    }
}
