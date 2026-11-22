import XCTest
import CryptoKit
@testable import MaskAI

final class CoordinatorTests: XCTestCase {
    private var moduleRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testInvalidDescriptorIsRejectedBeforeSubmission() async throws {
        let store = try MaskSnapshotStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models"))
        let coordinator = MaskAICoordinator(client: client, store: store)
        let source = MaskSourceBinding(sourceContentID: String(repeating: "a", count: 64),
                                       nativeWidth: 1, nativeHeight: 1, analysisWidth: 1, analysisHeight: 1, exifOrientation: 1)
        let invalid = SemanticMaskDescriptor(kind: .object, source: source, models: [MaskModelIdentity(model: .isnet)])
        do {
            _ = try await coordinator.submit(descriptor: invalid, image: NativeImage(width: 1, height: 1, rgba: [0, 0, 0, 255]))
            XCTFail("Invalid descriptor was accepted.")
        } catch {
            XCTAssertTrue(error is MaskAIError)
        }
    }

    func testSubjectSnapshotCacheAndRelease() async throws {
        try requireModels()
        let fixture = moduleRoot.appending(path: "Fixtures/Downloaded/car.png")
        let image = try NativeImage(contentsOf: fixture)
        let store = try MaskSnapshotStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models"))
        let coordinator = MaskAICoordinator(client: client, store: store)
        let descriptor = try descriptor(kind: .subject, image: image, fixture: fixture)
        let firstJob = try await coordinator.submit(descriptor: descriptor, image: image)
        let first = try await firstJob.result()
        let secondJob = try await coordinator.submit(descriptor: descriptor, image: image)
        let second = try await secondJob.result()
        XCTAssertFalse(first.cacheHit)
        XCTAssertTrue(second.cacheHit)
        XCTAssertLessThan(second.elapsedMilliseconds, first.elapsedMilliseconds)
        XCTAssertEqual(try store.load(first.snapshot.reference), try store.load(second.snapshot.reference))
        await coordinator.releaseResources()
        XCTAssertFalse(client.hasLoadedModels)
        XCTAssertFalse(client.objects.hasCachedEmbedding)
        XCTAssertFalse(client.scenes.hasCachedAnalysis)
    }

    func testCancellationDoesNotCommitSnapshot() async throws {
        try requireModels()
        let fixture = moduleRoot.appending(path: "Fixtures/Downloaded/car.png")
        let image = try NativeImage(contentsOf: fixture)
        let store = try MaskSnapshotStore(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let client = MaskAIClient(modelRoot: moduleRoot.appending(path: "Vendor/Models"))
        let coordinator = MaskAICoordinator(client: client, store: store)
        let descriptor = try descriptor(kind: .subject, image: image, fixture: fixture)
        let job = try await coordinator.submit(descriptor: descriptor, image: image)
        try await Task.sleep(nanoseconds: 100_000_000)
        await coordinator.cancel(job)
        do {
            _ = try await job.result()
            XCTFail("Cancelled job unexpectedly committed a result.")
        } catch MaskAIError.cancelled {
            // Expected native cancellation.
        }
        XCTAssertNil(try store.latest(for: descriptor))
        await coordinator.releaseResources()
        XCTAssertFalse(client.hasLoadedModels)
    }

    private func requireModels() throws {
        if ProcessInfo.processInfo.environment["MASK_AI_MODEL_TESTS"] != "1" {
            throw XCTSkip("Set MASK_AI_MODEL_TESTS=1 for native coordinator model tests.")
        }
    }

    private func descriptor(kind: SemanticMaskKind, image: NativeImage, fixture: URL) throws -> SemanticMaskDescriptor {
        let sourceData = try Data(contentsOf: fixture)
        let id = SHA256.hash(data: sourceData).map { String(format: "%02x", $0) }.joined()
        return SemanticMaskDescriptor(kind: kind,
                                      source: MaskSourceBinding(sourceContentID: id,
                                                                nativeWidth: image.width, nativeHeight: image.height,
                                                                analysisWidth: image.width, analysisHeight: image.height,
                                                                exifOrientation: 1),
                                      models: [MaskModelIdentity(model: .isnet)])
    }
}
