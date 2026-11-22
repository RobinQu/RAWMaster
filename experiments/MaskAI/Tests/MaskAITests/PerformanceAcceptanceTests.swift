import XCTest
@testable import MaskAI

final class PerformanceAcceptanceTests: XCTestCase {
    private struct Record: Codable {
        let name: String
        let elapsedMilliseconds: Double
        let budgetMilliseconds: Double
        let cacheHit: Bool
        let currentRSSBytes: Int64
        let maximumRSSBytes: Int64
        var passed: Bool
    }
    private struct Report: Codable {
        let sourceSHA256: String
        let records: [Record]
        let initialMemory: MemorySample
        let releasedMemory: MemorySample
        let maximumMemoryBudgetBytes: Int64
        let memoryPassed: Bool
        let resourcesReleased: Bool
        var passed: Bool
    }

    private var moduleRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testRealRAWPerformanceAcceptance() async throws {
        guard ProcessInfo.processInfo.environment["MASK_AI_PERFORMANCE_TESTS"] == "1" else {
            throw XCTSkip("Set MASK_AI_PERFORMANCE_TESTS=1 for real-RAW performance acceptance.")
        }
        let output = moduleRoot.appending(path: "Validation/Performance")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let snapshotRoot = output.appending(path: "Snapshots")
        try? FileManager.default.removeItem(at: snapshotRoot)
        let loaded = try RAWImageAdapter.load(moduleRoot.appending(path: "Fixtures/RAW/sony-sample-03.ARW"))
        let store = try MaskSnapshotStore(root: output.appending(path: "Snapshots"))
        let client = MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models"))
        let coordinator = MaskAICoordinator(client: client, store: store)
        let source = MaskSourceBinding(info: loaded.info)
        var records: [Record] = []
        let initial = MemoryMeter.sample()

        let subject = SemanticMaskDescriptor(kind: .subject, source: source, models: [.init(model: .isnet)])
        let subjectCold = try await measure("subject.cold", budget: 6000, coordinator: coordinator,
                                            descriptor: subject, image: loaded.image)
        records.append(subjectCold)
        records.append(try await measure("subject.snapshotHit", budget: 250, coordinator: coordinator,
                                         descriptor: subject, image: loaded.image))

        let models = [MaskModelIdentity(model: .efficientViT)]
        let water = SemanticMaskDescriptor(kind: .landscape, target: LandscapeMaskTarget.water.rawValue, source: source, models: models)
        records.append(try await measure("landscape.firstScene", budget: 6000, coordinator: coordinator,
                                         descriptor: water, image: loaded.image))
        let ground = SemanticMaskDescriptor(kind: .landscape, target: LandscapeMaskTarget.naturalGround.rawValue, source: source, models: models)
        records.append(try await measure("landscape.sharedScene", budget: 1500, coordinator: coordinator,
                                         descriptor: ground, image: loaded.image))

        let objectModels = [MaskModelIdentity(model: .slimSAMEncoder), MaskModelIdentity(model: .slimSAMDecoder)]
        let point = SemanticMaskDescriptor(kind: .object,
                                           objectPrompt: ObjectPrompt(positivePoints: [.init(x: 0.60, y: 0.53)]),
                                           source: source, models: objectModels)
        records.append(try await measure("object.firstPrompt", budget: 6000, coordinator: coordinator,
                                         descriptor: point, image: loaded.image))
        let box = SemanticMaskDescriptor(kind: .object,
                                         objectPrompt: ObjectPrompt(box: .init(x: 0.47, y: 0.45, width: 0.22, height: 0.20)),
                                         source: source, models: objectModels)
        records.append(try await measure("object.cachedEncoder", budget: 2000, coordinator: coordinator,
                                         descriptor: box, image: loaded.image))

        XCTAssertFalse(subjectCold.cacheHit)
        XCTAssertTrue(records[1].cacheHit)
        for index in [2, 3, 4, 5] { XCTAssertFalse(records[index].cacheHit, "Unexpected snapshot hit at record \(index).") }

        let subjectSnapshot = try XCTUnwrap(store.latest(for: subject))
        let snapshotStarted = Date()
        _ = try store.load(subjectSnapshot.reference)
        records.append(makeRecord(name: "snapshot.read", elapsed: Date().timeIntervalSince(snapshotStarted) * 1000,
                                  budget: 100, cacheHit: true))

        // Use a separate, uncached IS-Net job so cancellation targets real inference rather than an already-finished prompt.
        let cancelImage = try NativeImage(contentsOf: moduleRoot.appending(path: "Fixtures/Downloaded/car.png"))
        let cancelSource = MaskSourceBinding(sourceContentID: "c6ae6440e3862dd9768cd9f7098b783ac980629dd7bc1fe69c10b39fca5a84cd",
                                             nativeWidth: cancelImage.width, nativeHeight: cancelImage.height,
                                             analysisWidth: cancelImage.width, analysisHeight: cancelImage.height, exifOrientation: 1)
        let cancelDescriptor = SemanticMaskDescriptor(kind: .subject, source: cancelSource, models: [.init(model: .isnet)])
        let cancelStarted = Date()
        let job = try await coordinator.submit(descriptor: cancelDescriptor, image: cancelImage)
        try await Task.sleep(nanoseconds: 100_000_000)
        await coordinator.cancel(job)
        do {
            _ = try await job.result()
            XCTFail("Cancellation benchmark unexpectedly committed a result.")
        } catch MaskAIError.cancelled {
            // Expected.
        }
        records.append(makeRecord(name: "subject.cancel", elapsed: Date().timeIntervalSince(cancelStarted) * 1000,
                                  budget: 2000, cacheHit: false))
        XCTAssertNil(try store.latest(for: cancelDescriptor))

        await coordinator.releaseResources()
        let released = MemoryMeter.sample()
        let releasedFlags = !client.hasLoadedModels && !client.objects.hasCachedEmbedding &&
            !client.scenes.hasCachedAnalysis && !client.people.hasCachedPeople
        let maximumBudget: Int64 = 4_000_000_000
        let maximum = max(initial.maximumRSSBytes, released.maximumRSSBytes, records.map(\.maximumRSSBytes).max() ?? 0)
        var report = Report(sourceSHA256: loaded.info.sourceSHA256, records: records,
                            initialMemory: initial, releasedMemory: released,
                            maximumMemoryBudgetBytes: maximumBudget, memoryPassed: maximum <= maximumBudget,
                            resourcesReleased: releasedFlags, passed: false)
        report.passed = report.memoryPassed && report.resourcesReleased && records.allSatisfy(\.passed)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: output.appending(path: "performance-results.json"))
        for record in records {
            print("PERF_RESULT \(record.name) ms=\(record.elapsedMilliseconds) budget=\(record.budgetMilliseconds) cacheHit=\(record.cacheHit) passed=\(record.passed)")
        }
        print("PERF_MEMORY initialRSS=\(initial.currentRSSBytes) releasedRSS=\(released.currentRSSBytes) maxRSS=\(maximum) budget=\(maximumBudget)")
        XCTAssertTrue(report.resourcesReleased)
        XCTAssertTrue(report.memoryPassed, "Maximum RSS \(maximum) exceeded budget \(maximumBudget).")
        for record in records where !record.passed {
            XCTFail("\(record.name): \(record.elapsedMilliseconds) ms exceeded \(record.budgetMilliseconds) ms.")
        }
    }

    private func measure(_ name: String, budget: Double, coordinator: MaskAICoordinator,
                         descriptor: SemanticMaskDescriptor, image: NativeImage) async throws -> Record {
        let started = Date()
        let job = try await coordinator.submit(descriptor: descriptor, image: image)
        let result = try await job.result()
        return makeRecord(name: name, elapsed: Date().timeIntervalSince(started) * 1000,
                          budget: budget, cacheHit: result.cacheHit)
    }

    private func makeRecord(name: String, elapsed: Double, budget: Double, cacheHit: Bool) -> Record {
        let memory = MemoryMeter.sample()
        return Record(name: name, elapsedMilliseconds: elapsed, budgetMilliseconds: budget,
                      cacheHit: cacheHit, currentRSSBytes: memory.currentRSSBytes,
                      maximumRSSBytes: memory.maximumRSSBytes, passed: elapsed <= budget)
    }
}
