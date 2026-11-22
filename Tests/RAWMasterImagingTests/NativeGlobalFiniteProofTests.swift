import CoreImage
import XCTest
@testable import RAWMasterImaging

final class NativeGlobalFiniteProofTests: XCTestCase {
    private func key(_ name: String) -> FlashRawCanonicalTextureKey {
        .init(sourceKey: name, captureStamp: .init(device: 1, inode: 2, size: 3, seconds: 4, nanoseconds: 5,
            changedSeconds: 6, changedNanoseconds: 7), contract: "linear-rgba", width: 2, height: 2)
    }

    func testProofFollowsOneLiveTextureAtOneStage() throws {
        let pool = FlashRawCanonicalTexturePool(byteBudget: 64, maximumEntries: 2)
        let image = CIImage(color: .black).cropped(to: .init(x: 0, y: 0, width: 2, height: 2))
        let otherGraph = image.applyingFilter("CIColorInvert")
        let a = key("A"), b = key("B")
        let pin = try pool.acquire(a) { image }
        let peer = try pool.acquire(a) { XCTFail("duplicate decode"); return image }
        let secondSource = try pool.acquire(b) { image }
        var scans = 0
        func validate() { scans += 1 }
        try pin.validateNativeGlobalOutput(image, cancellation: nil, validate: validate)
        try peer.validateNativeGlobalOutput(image, cancellation: nil, validate: validate)
        XCTAssertEqual(scans, 1)
        try peer.validateNativeGlobalOutput(otherGraph, cancellation: nil, validate: validate)
        try peer.validateNativeGlobalOutput(otherGraph, cancellation: nil, validate: validate)
        try secondSource.validateNativeGlobalOutput(image, cancellation: nil, validate: validate)
        XCTAssertEqual(scans, 4)
        XCTAssertThrowsError(try peer.validateNativeGlobalOutput(image, cancellation: { throw CancellationError() },
            validate: { XCTFail("cancelled hit") }))
        pool.retire(sourceKey: a.sourceKey)
        try peer.validateNativeGlobalOutput(image, cancellation: nil, validate: validate)
        pin.release()
        peer.release()
        let restored = try pool.acquire(a) { image }
        try restored.validateNativeGlobalOutput(image, cancellation: nil, validate: validate)
        XCTAssertEqual(scans, 6)
        restored.release()
        secondSource.release()
        XCTAssertEqual(pool.statistics().pinnedBytes, 0)
    }

    func testFailedCancelledAndOverlappingScansNeverPublishAnUnfinishedProof() throws {
        let pool = FlashRawCanonicalTexturePool(byteBudget: 32, maximumEntries: 1)
        let input = CIImage(color: .white).cropped(to: .init(x: 0, y: 0, width: 2, height: 2))
        let owner = try pool.acquire(key("shared")) { input }
        let peer = try pool.acquire(key("shared")) { input }
        XCTAssertThrowsError(try owner.validateNativeGlobalOutput(input, cancellation: nil,
            validate: { throw CocoaError(.fileReadCorruptFile) }))
        var checks = 0, scans = 0
        XCTAssertThrowsError(try owner.validateNativeGlobalOutput(input, cancellation: {
            checks += 1
            if checks == 2 { throw CancellationError() }
        }, validate: { scans += 1 }))
        XCTAssertEqual(scans, 1)
        let entered = DispatchSemaphore(value: 0), joined = DispatchSemaphore(value: 0)
        let finished = expectation(description: "prior scan finishes")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                try owner.validateNativeGlobalOutput(input, cancellation: nil) {
                    entered.signal()
                    XCTAssertEqual(joined.wait(timeout: .now() + 5), .success)
                }
            } catch { XCTFail("unexpected scan failure \(error)") }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success)
        try peer.validateNativeGlobalOutput(input, cancellation: nil) { scans += 1 }
        XCTAssertEqual(scans, 2)
        joined.signal()
        wait(for: [finished], timeout: 5)
        try peer.validateNativeGlobalOutput(input, cancellation: nil) { XCTFail("expected completed evidence") }
        owner.release()
        peer.release()
    }
}
