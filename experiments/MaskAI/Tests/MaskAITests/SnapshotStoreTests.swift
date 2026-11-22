import XCTest
@testable import MaskAI

final class SnapshotStoreTests: XCTestCase {
    private var temporary: URL!
    private var store: MaskSnapshotStore!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appending(path: "MaskAI-Snapshot-Tests-\(UUID().uuidString)")
        store = try MaskSnapshotStore(root: temporary)
    }
    override func tearDownWithError() throws {
        if let temporary { try? FileManager.default.removeItem(at: temporary) }
        store = nil
    }

    private func descriptor(source: String = "a", prompt: ObjectPrompt? = nil) throws -> SemanticMaskDescriptor {
        let kind: SemanticMaskKind = prompt == nil ? .subject : .object
        return SemanticMaskDescriptor(kind: kind, objectPrompt: prompt,
                                      source: MaskSourceBinding(sourceContentID: String(repeating: source, count: 64),
                                                                nativeWidth: 2, nativeHeight: 2,
                                                                analysisWidth: 2, analysisHeight: 2, exifOrientation: 1),
                                      models: [MaskModelIdentity(model: .isnet)])
    }

    func testSnapshotRoundTripAndLatest() throws {
        let descriptor = try descriptor()
        let mask = try MaskImage(width: 2, height: 2, values: [0, 64, 128, 255])
        let saved = try store.save(mask: mask, descriptor: descriptor)
        XCTAssertEqual(try saved.loadMask(from: store), mask)
        XCTAssertEqual(try store.latest(for: descriptor), saved)
        XCTAssertEqual(saved.reference.byteCount, 4)
    }

    func testRefreshKeepsImmutableHistory() throws {
        let descriptor = try descriptor()
        let first = try store.save(mask: MaskImage(width: 2, height: 2, values: [0, 0, 0, 0]), descriptor: descriptor)
        let second = try store.save(mask: MaskImage(width: 2, height: 2, values: [255, 255, 255, 255]), descriptor: descriptor)
        XCTAssertNotEqual(first.reference.id, second.reference.id)
        XCTAssertEqual(try store.latest(for: descriptor), second)
        XCTAssertEqual(try store.load(first.reference).values, [0, 0, 0, 0])
        XCTAssertEqual(try store.load(second.reference).values, [255, 255, 255, 255])
    }

    func testCorruptionAndWrongDimensionsAreRejected() throws {
        let descriptor = try descriptor()
        let saved = try store.save(mask: MaskImage(width: 2, height: 2, values: [1, 2, 3, 4]), descriptor: descriptor)
        let dataURL = temporary.appending(path: "Snapshots/\(saved.reference.id).gray8")
        try Data([9, 9, 9, 9]).write(to: dataURL)
        XCTAssertThrowsError(try store.load(saved.reference))
        let wrong = try MaskImage(width: 1, height: 1, values: [255])
        XCTAssertThrowsError(try store.save(mask: wrong, descriptor: descriptor))
    }

    func testDescriptorIdentityAndValidation() throws {
        let subject = try descriptor(source: "a")
        let other = try descriptor(source: "b")
        XCTAssertNotEqual(try subject.cacheKey, try other.cacheKey)
        let prompted = try descriptor(prompt: ObjectPrompt(positivePoints: [.init(x: 0.5, y: 0.5)]))
        XCTAssertEqual(prompted.kind, .object)
        XCTAssertNoThrow(try prompted.validate())
        let invalid = SemanticMaskDescriptor(kind: .object, source: subject.source, models: [MaskModelIdentity(model: .isnet)])
        XCTAssertThrowsError(try invalid.validate())
    }

    func testDiscardRemovesCancelledCommit() throws {
        let descriptor = try descriptor()
        let snapshot = try store.save(mask: MaskImage(width: 2, height: 2, values: [1, 2, 3, 4]), descriptor: descriptor)
        try store.discard(snapshot)
        XCTAssertNil(try store.latest(for: descriptor))
        XCTAssertThrowsError(try store.load(snapshot.reference))
    }

    func testConcurrentSaveKeepsReadableSnapshot() throws {
        let descriptor = try descriptor()
        let mask = try MaskImage(width: 2, height: 2, values: [10, 20, 30, 40])
        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            do { _ = try self.store.save(mask: mask, descriptor: descriptor) }
            catch { XCTFail("Concurrent save failed: \(error)") }
        }
        XCTAssertEqual(try store.latest(for: descriptor)?.loadMask(from: store), mask)
    }
}
