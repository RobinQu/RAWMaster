import XCTest
import CryptoKit
import RAWMasterCore
import Darwin
@testable import RAWMasterImaging

final class OrderedMetadataWorkersTests: XCTestCase {
    private final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var active = 0, maximum = 0, started = 0, finished = 0
        private var cancelled = false
        @discardableResult func enter() -> Int { lock.lock(); defer { lock.unlock() }; active += 1; started += 1; maximum = max(maximum, active); return started }
        func leave() { lock.lock(); defer { lock.unlock() }; active -= 1; finished += 1 }
        func cancel() { lock.lock(); defer { lock.unlock() }; cancelled = true }
        func check() throws { lock.lock(); defer { lock.unlock() }; if cancelled { throw CancellationError() } }
        var snapshot: (active: Int, maximum: Int, started: Int, finished: Int) {
            lock.lock(); defer { lock.unlock() }; return (active, maximum, started, finished)
        }
    }
    private enum Failure: Error { case provider, rendezvousTimeout }

    func testConcurrencyIsBoundedAndOutputsKeepInputOrder() throws {
        let observation = Observation()
        let values = try OrderedMetadataWorkers.map(Array(0..<24), limit: 3, check: {}) { index, value, check in
            observation.enter(); defer { observation.leave() }
            if index < 3 {
                // Ensure all three workers have started before any may finish.
                let deadline = Date().addingTimeInterval(2)
                while observation.snapshot.started < 3 {
                    guard Date() < deadline else { throw Failure.rendezvousTimeout }
                    try check(); Thread.sleep(forTimeInterval: 0.001)
                }
            }
            Thread.sleep(forTimeInterval: Double(3 - index % 3) * 0.001)
            return value * 7
        }
        XCTAssertEqual(values, Array(0..<24).map { $0 * 7 })
        XCTAssertEqual(observation.snapshot.maximum, 3)
        XCTAssertEqual(observation.snapshot.active, 0)
        XCTAssertEqual(observation.snapshot.finished, 24)
    }

    func testFailureStopsAdmissionAndJoinsCancelledSibling() {
        let observation = Observation()
        XCTAssertThrowsError(try OrderedMetadataWorkers.map(Array(0..<100), limit: 2, check: {}) { index, _, check -> Int in
            observation.enter(); defer { observation.leave() }
            let deadline = Date().addingTimeInterval(2)
            while observation.snapshot.started < 2 {
                guard Date() < deadline else { throw Failure.rendezvousTimeout }
                Thread.sleep(forTimeInterval: 0.001)
            }
            if index == 0 { throw Failure.provider }
            while true { try check(); Thread.sleep(forTimeInterval: 0.001) }
        }) { XCTAssertTrue($0 is Failure) }
        XCTAssertEqual(observation.snapshot.started, 2)
        XCTAssertEqual(observation.snapshot.finished, 2)
        XCTAssertEqual(observation.snapshot.active, 0)
    }

    func testExternalCancellationJoinsAllWorkersBeforeReturning() {
        let observation = Observation()
        DispatchQueue.global().async {
            let deadline = Date().addingTimeInterval(2)
            while observation.snapshot.started < 4 && Date() < deadline { Thread.sleep(forTimeInterval: 0.001) }
            observation.cancel()
        }
        XCTAssertThrowsError(try OrderedMetadataWorkers.map(Array(0..<100), limit: 4, check: { try observation.check() }) { _, _, check -> Int in
            observation.enter(); defer { observation.leave() }
            while true { try check(); Thread.sleep(forTimeInterval: 0.001) }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertGreaterThan(observation.snapshot.started, 0)
        XCTAssertLessThanOrEqual(observation.snapshot.started, 4)
        XCTAssertEqual(observation.snapshot.finished, observation.snapshot.started)
        XCTAssertEqual(observation.snapshot.active, 0)
    }

    func testParentTaskCancellationReachesDetachedAndDispatchedWorkersAndJoins() async {
        let observation = Observation(), ready = expectation(description: "Dispatched workers started")
        let task = Task.detached {
            try await OrderedMetadataWorkers.offMain(check: {}) { checkpoint in
                try OrderedMetadataWorkers.map(Array(0..<100), limit: 4, check: checkpoint) { _, _, check -> Int in
                    if observation.enter() == 4 { ready.fulfill() }
                    defer { observation.leave() }
                    while true { try check(); Thread.sleep(forTimeInterval: 0.001) }
                }
            }
        }
        await fulfillment(of: [ready], timeout: 30)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancellation must reach blocking workers") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(observation.snapshot.started, 4)
        XCTAssertEqual(observation.snapshot.finished, 4)
        XCTAssertEqual(observation.snapshot.active, 0)
    }

    func testEmptyInputAndSingleWorkerRespectCancellation() throws {
        XCTAssertEqual(try OrderedMetadataWorkers.map([Int](), limit: 4, check: {}, transform: { _, value, _ in value }), [])
        XCTAssertThrowsError(try OrderedMetadataWorkers.map([Int](), limit: 4, check: { throw CancellationError() }, transform: { _, value, _ in value }))
        let observation = Observation()
        let result = try OrderedMetadataWorkers.map([2, 4, 6], limit: 0, check: {}) { _, value, _ in
            observation.enter(); defer { observation.leave() }; return value
        }
        XCTAssertEqual(result, [2, 4, 6]); XCTAssertEqual(observation.snapshot.maximum, 1)
    }

    func testConcurrentChildrenCloseUnrelatedParentPipesAndKeepExplicitStdio() throws {
        var unrelated: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&unrelated), 0)
        defer { close(unrelated[0]); close(unrelated[1]) }
        // Plain parent pipes intentionally have no FD_CLOEXEC flag, like sibling worker pipes.
        XCTAssertEqual(fcntl(unrelated[1], F_GETFD) & FD_CLOEXEC, 0)
        let descriptor = unrelated[1]
        let values = try OrderedMetadataWorkers.map(Array(0..<8), limit: 4, check: {}) { _, _, check in
            let script = "if (open(my $p, '>&=\(descriptor)')) { print 'inherited' } else { print 'closed' }; print STDERR 'stdio-ok';"
            return try RuntimeMetadataChild.run(arguments: ["-e", script], check: check)
        }
        XCTAssertEqual(values, Array(repeating: Data("closed".utf8), count: 8))
    }

    func testOptInRealMetadataAndNativeFeaturesMatchSequentialReads() throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["RAWMASTER_RUNTIME_RAW_DIRECTORY"], let toolRoot = env["RAWMASTER_RUNTIME_TOOL_ROOT"] else {
            throw XCTSkip("Set bounded RAW directory and tool root for actual metadata concurrency comparison")
        }
        let urls = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: source), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "arw" }.sorted { $0.path < $1.path }
        guard !urls.isEmpty, urls.count <= 12 else { throw XCTSkip("Comparison requires 1–12 original ARWs") }
        struct Input: Sendable { let url: URL; let hash: String; let credential: SequenceFileCredential }
        struct Capture: Sendable, Equatable {
            let metadata: RuntimeNormalizedMetadata
            let evidence: SequenceCaptureEvidence
            let feature: SequenceFrameFeature?
        }
        let tool = try RuntimeSequenceTool(root: URL(fileURLWithPath: toolRoot))
        let key = SymmetricKey(data: Data(repeating: 71, count: 32))
        let inputs = try urls.map { url -> Input in
            let credential = try SequenceFileCredential.capture(at: url), hash = try RuntimeSequenceTool.hash(url)
            XCTAssertEqual(try SequenceFileCredential.capture(at: url), credential)
            return Input(url: url, hash: hash, credential: credential)
        }
        let read: @Sendable (Int, Input, @escaping @Sendable () throws -> Void) throws -> Capture = { index, input, check in
            let metadata = try RuntimeJSONQ.normalize(tool.read(input.url, check: check), expectedSource: input.url.path, key: key)
            let native = try SequenceCaptureReader.read(at: input.url, assetID: String(index), contentHash: input.hash,
                evidenceRevision: 1, verifiedCredential: input.credential, cancelled: { (try? check()) == nil })
            return Capture(metadata: metadata, evidence: native.evidence, feature: native.feature)
        }
        let started = ProcessInfo.processInfo.systemUptime
        let serial = try OrderedMetadataWorkers.map(inputs, limit: 1, check: {}, transform: read)
        let serialSeconds = ProcessInfo.processInfo.systemUptime - started
        let concurrentStart = ProcessInfo.processInfo.systemUptime
        let concurrent = try OrderedMetadataWorkers.map(inputs, limit: 4, check: {}, transform: read)
        let concurrentSeconds = ProcessInfo.processInfo.systemUptime - concurrentStart
        XCTAssertEqual(concurrent, serial)
        for input in inputs { XCTAssertEqual(try RuntimeSequenceTool.hash(input.url), input.hash) }
        print("METADATA_WORKER_BENCHMARK files=\(inputs.count) sequentialSeconds=\(serialSeconds) concurrentSeconds=\(concurrentSeconds)")
    }
}
