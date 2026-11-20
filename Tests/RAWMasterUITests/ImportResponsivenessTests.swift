import Foundation
import XCTest
import Combine
import RAWMasterCore
@testable import RAWMaster

final class ImportResponsivenessTests: XCTestCase {
    private final class SnapshotGate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var entered = false
        var hasEntered: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        func holdFirstRead() {
            lock.lock()
            guard !entered else { lock.unlock(); return }
            entered = true; lock.unlock()
            _ = release.wait(timeout: .now() + 10)
        }
        func open() { release.signal() }
    }
    private actor GroupingGate {
        private var released = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if released { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() { released = true; waiter?.resume(); waiter = nil }
    }
    @MainActor private func waitUntil(_ predicate: () -> Bool, timeout: TimeInterval = 10) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Timed out waiting for import state"); return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    private func source(_ fixture: AppModelTests.Fixture, count: Int, name: String) throws -> URL {
        let url = fixture.root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for index in 0..<count {
            try Data("import-\(name)-\(index)".utf8).write(to: url.appendingPathComponent("\(index).jpg"))
        }
        return url
    }

    @MainActor func testSlowSnapshotLeavesMainActorAvailableAndCannotOverwriteNewerReload() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        _ = try await fixture.populate(count: 4)
        let original = try XCTUnwrap(fixture.store.loadAssets().first)
        let incoming = try source(fixture, count: 64, name: "incoming")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: { _, _, _ in })
        let gate = SnapshotGate(); defer { gate.open() }
        model.backgroundSnapshotReadHook = { gate.holdFirstRead() }
        model.startImport(source: incoming.path, destination: "", name: "Incoming", mode: .reference, projectID: nil)
        try await waitUntil({ gate.hasEntered })
        XCTAssertTrue(model.isBusy, "A final snapshot must be awaited before the job can end")
        var heartbeats = 0
        let started = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime - started < 0.1 {
            try await Task.sleep(nanoseconds: 5_000_000)
            heartbeats += 1
        }
        XCTAssertGreaterThan(heartbeats, 5, "Worker snapshot must not occupy MainActor")
        _ = try fixture.store.updateSelection(ids: [original.id], decision: .keep, rating: 4)
        model.reload() // Invalidates the older worker result before it can be published.
        model.backgroundSnapshotReadHook = nil
        gate.open()
        try await waitUntil({ !model.isBusy })
        XCTAssertEqual(model.assets.count, 68)
        XCTAssertEqual(model.assets.first(where: { $0.id == original.id })?.decision, .keep)
        XCTAssertEqual(model.assets.first(where: { $0.id == original.id })?.rating, 4)
        XCTAssertEqual(model.assets.map(\.id), AssetBrowserOrder.sorted(try fixture.store.loadAssets(), sessions: try fixture.store.loadSessions()).map(\.id))
        XCTAssertEqual(model.qualityEvidence.count, 64, "Last quality results must be visible when its task finishes")
        XCTAssertNil(model.sessionTask)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testCancellationDrainsSnapshotAndNextImportUsesItsOwnGeneration() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let incoming = try source(fixture, count: 64, name: "cancelled")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: { _, _, _ in })
        let gate = SnapshotGate(); defer { gate.open() }
        model.backgroundSnapshotReadHook = { gate.holdFirstRead() }
        model.startImport(source: incoming.path, destination: "", name: "Cancel", mode: .reference, projectID: nil)
        try await waitUntil({ gate.hasEntered })
        model.cancelJob()
        model.backgroundSnapshotReadHook = nil
        gate.open()
        try await waitUntil({ !model.isBusy })
        XCTAssertEqual(Set(model.assets.map(\.id)), Set(try fixture.store.loadAssets().map(\.id)))
        XCTAssertNil(model.sessionTask)
        let next = try source(fixture, count: 3, name: "next")
        model.startImport(source: next.path, destination: "", name: "Next", mode: .reference, projectID: nil)
        try await waitUntil({ !model.isBusy })
        let session = try XCTUnwrap(model.sessions.first { $0.projectName == "Next" })
        XCTAssertEqual(model.scopeID, session.id)
        XCTAssertEqual(model.assets.filter { $0.sessionID == session.id }.count, 3)
        let nextIDs = Set(model.assets.filter { $0.sessionID == session.id }.map(\.id))
        XCTAssertEqual(model.qualityEvidence.filter { nextIDs.contains($0.assetID) }.count, 3)
        XCTAssertEqual(model.progress?.isRunning, false)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testGroupingProgressDoesNotRereadOrRepublishPhotoArraysAndFinalCommitRefreshes() async throws {
        let fixture = try AutomaticGroupingWorkflowUITests.Fixture(); defer { fixture.clean() }
        let session = try await ImportService(store: fixture.store, postIngest: fixture.callback()).importDirectory(
            source: fixture.source, destination: nil, projectName: "Grouping refresh", mode: .reference,
            initialScreening: true, progress: { _ in })
        let gate = GroupingGate()
        let emitted = expectation(description: "100 grouping progress callbacks emitted")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: fixture.callback(),
            regroupAnalyzer: { input, check, progress in
                for index in 1...100 {
                    try check()
                    progress(TaskProgress(title: "Grouping metadata", completed: index, total: 100))
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                emitted.fulfill()
                await gate.wait()
                try check()
                return try AutomaticGroupingWorkflowUITests.analysis(input, kind: .interval, ranges: [0...3])
            })
        model.selectScope(.session, id: session.id)
        let originalGroups = Set(model.groups.map(\.id))
        var readCount = 0, publications = 0
        model.backgroundSnapshotDidRead = { _ in readCount += 1 }
        let observation = model.$assets.sink { _ in publications += 1 }
        model.regroup(sessionID: session.id)
        await fulfillment(of: [emitted], timeout: 5)
        try await Task.sleep(nanoseconds: 150_000_000) // Drain the last coalesced progress value.
        XCTAssertEqual(readCount, 1, "Only the initial running-state snapshot is needed during grouping")
        XCTAssertEqual(publications, 2, "Initial Combine delivery plus one boundary snapshot; progress must not republish arrays")
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.progress?.isRunning == true)
        XCTAssertEqual(model.progress?.completed, 100)
        XCTAssertEqual(Set(model.groups.map(\.id)), originalGroups, "Uncommitted grouping must preserve visible old groups")
        model.reload() // Explicit human refresh remains available during pure grouping.
        XCTAssertEqual(publications, 3)
        XCTAssertEqual(readCount, 1)
        await gate.open()
        try await waitUntil({ !model.isBusy })
        withExtendedLifetime(observation) {}
        XCTAssertEqual(readCount, 2, "The final committed grouping result must always be read")
        XCTAssertEqual(publications, 4)
        XCTAssertTrue(originalGroups.isDisjoint(with: model.groups.map(\.id)))
        XCTAssertEqual(model.groups.count, 1)
        XCTAssertEqual(model.automaticGroupingRun?.state, .applied)
        XCTAssertFalse(model.progress?.isRunning == true)
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testGroupingCancellationAndFailureStillPublishFinalSnapshot() async throws {
        for cancelled in [true, false] {
            let fixture = try AutomaticGroupingWorkflowUITests.Fixture(); defer { fixture.clean() }
            let session = try await ImportService(store: fixture.store, postIngest: fixture.callback()).importDirectory(
                source: fixture.source, destination: nil, projectName: "Grouping terminal", mode: .reference,
                initialScreening: true, progress: { _ in })
            let gate = GroupingGate()
            let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: fixture.callback(),
                regroupAnalyzer: { _, check, progress in
                    progress(TaskProgress(title: "Grouping held", completed: 1, total: 100))
                    await gate.wait()
                    try check()
                    throw LibraryError.invalid("Deliberate grouping failure")
                })
            model.selectScope(.session, id: session.id)
            let originalGroups = Set(model.groups.map(\.id))
            var reads = 0
            model.backgroundSnapshotDidRead = { _ in reads += 1 }
            model.regroup(sessionID: session.id)
            try await waitUntil({ reads == 1 })
            if cancelled { model.cancelSessionTask() }
            await gate.open()
            try await waitUntil({ !model.isBusy })
            XCTAssertEqual(reads, 2, "Cancellation and failure must drain a fresh final snapshot")
            XCTAssertEqual(model.automaticGroupingRun?.state, cancelled ? .cancelled : .failed)
            XCTAssertEqual(Set(model.groups.map(\.id)), originalGroups)
            XCTAssertFalse(model.progress?.isRunning == true)
            XCTAssertNil(model.sessionTask)
        }
    }

    @MainActor func testIntakeToGroupingBoundaryPublishesCompletedIntakeBeforeAnalyzerReturns() async throws {
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let incoming = try source(fixture, count: 64, name: "grouping-boundary")
        let gate = GroupingGate()
        let entered = expectation(description: "post-ingest grouping entered")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: { _, _, progress in
            progress(TaskProgress(title: "Grouping held", total: 64))
            entered.fulfill()
            await gate.wait()
        })
        model.startImport(source: incoming.path, destination: "", name: "Boundary", mode: .reference, projectID: nil)
        await fulfillment(of: [entered], timeout: 5)
        try await waitUntil({ model.sessionTask?.kind == .grouping && model.assets.count == 64 })
        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.assets.allSatisfy { $0.importState == .ready })
        XCTAssertEqual(model.scope, .session)
        XCTAssertEqual(model.scopeID, model.sessionTask?.sessionID)
        XCTAssertTrue(model.progress?.isRunning == true)
        await gate.open()
        try await waitUntil({ !model.isBusy })
        XCTAssertEqual(model.qualityEvidence.count, 64)
        XCTAssertNil(model.errorMessage)
    }

    /// Controller scheduling benchmark, deliberately excluding WindowServer/SwiftUI presentation.
    /// Enable explicitly so ordinary regression runs don't repeatedly import thousands of fixtures.
    @MainActor func testOptionalLargeImportMainActorHeartbeat() async throws {
        guard let output = ProcessInfo.processInfo.environment["RAWMASTER_IMPORT_UI_BENCHMARK"] else {
            throw XCTSkip("Set RAWMASTER_IMPORT_UI_BENCHMARK to the JSON report path")
        }
        let fixture = try AppModelTests.Fixture(); defer { fixture.clean() }
        let fileCount = 3_000
        let incoming = try source(fixture, count: fileCount, name: "large")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, postIngest: { _, _, _ in })
        var applies: [Double] = [], reads: [Double] = []
        model.backgroundSnapshotDidApply = { applies.append($0 * 1_000) }
        model.backgroundSnapshotDidRead = { reads.append($0 * 1_000) }
        var gaps: [Double] = []
        let started = ProcessInfo.processInfo.systemUptime
        var lastBeat = started
        model.startImport(source: incoming.path, destination: "", name: "Large import", mode: .reference, projectID: nil)
        while model.isBusy {
            try await Task.sleep(nanoseconds: 5_000_000)
            let now = ProcessInfo.processInfo.systemUptime
            gaps.append((now - lastBeat) * 1_000); lastBeat = now
            guard now - started < 120 else { model.cancelJob(); XCTFail("Large import exceeded benchmark time budget"); break }
        }
        try await waitUntil({ !model.isBusy })
        let sorted = gaps.sorted()
        let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))]
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let report: [String: Any] = ["files": fileCount, "elapsedSeconds": elapsed,
            "heartbeatSamples": gaps.count, "heartbeatP95Milliseconds": p95,
            "heartbeatMaxMilliseconds": gaps.max() ?? 0, "snapshotApplyMilliseconds": applies,
            "snapshotApplyMaxMilliseconds": applies.max() ?? 0,
            "snapshotReadMilliseconds": reads, "snapshotReadMaxMilliseconds": reads.max() ?? 0,
            "persistedFiles": try fixture.store.loadAssets().count, "visibleFiles": model.assets.count,
            "scope": "synthetic local controller import and quality; no automatic grouping or UI presentation"]
        let destination = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination)
        XCTAssertEqual(model.assets.count, fileCount)
        XCTAssertEqual(model.qualityEvidence.count, fileCount)
        XCTAssertGreaterThan(gaps.count, 10)
        XCTAssertLessThan(p95, 100, "The controller should service its MainActor heartbeat during real imports")
        XCTAssertNil(model.errorMessage)
    }

    @MainActor func testProgressStormCoalescesBeforeActorDeliveryAndCloseRetainsLastValue() async throws {
        var deliveries: [Int] = []
        let mailbox = ImportProgressMailbox { deliveries.append($0.completed) }
        // MainActor stays occupied while the producer submits, so the 10,000 callbacks
        // must share one pending delivery rather than create 10,000 actor tasks.
        for index in 0..<10_000 { mailbox.submit(TaskProgress(title: "Import", completed: index, total: 10_000)) }
        XCTAssertTrue(deliveries.isEmpty)
        try await waitUntil({ !deliveries.isEmpty })
        XCTAssertEqual(deliveries, [9_999])
        mailbox.submit(TaskProgress(title: "Import", completed: 10_000, total: 10_000, isRunning: false))
        XCTAssertEqual(mailbox.close()?.completed, 10_000)
        mailbox.submit(TaskProgress(title: "Late callback", completed: -1))
        try await Task.sleep(nanoseconds: 120_000_000)
        XCTAssertEqual(deliveries, [9_999], "Closed mailboxes cannot publish callbacks after task completion")
    }
}
