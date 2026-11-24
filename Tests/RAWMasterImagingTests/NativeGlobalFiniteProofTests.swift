import CoreImage
import Metal
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
        XCTAssertFalse(pin.hasCheckedOpaqueUpload(for:image))
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

    func testPrivateTextureProofChecksEveryChannelAndClippedLastGroup() throws {
        guard let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
            throw XCTSkip("The checked native upload requires unified memory")
        }
        let width = 129, height = 33
        let stride = ((width * 8 + 255) / 256) * 256
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: width, height: height, mipmapped: false)
        descriptor.storageMode = .private
        descriptor.usage = [.shaderRead, .shaderWrite]
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let upload = try XCTUnwrap(device.makeBuffer(length: stride * height, options: .storageModeShared))
        let bytes = upload.contents().bindMemory(to: UInt16.self, capacity: stride * height / 2)
        for y in 0..<height {
            for x in 0..<width {
                let pixel = bytes.advanced(by: y * stride / 2 + 4 * x)
                pixel[0] = 0xfbff
                pixel[1] = 0x8001
                pixel[2] = 0x7bff
                pixel[3] = 0x3c00
            }
        }
        func finishUpload() throws {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeBlitCommandEncoder())
            encoder.copy(from: upload, sourceOffset: 0, sourceBytesPerRow: stride, sourceBytesPerImage: stride * height,
                         sourceSize: .init(width: width, height: height, depth: 1), to: texture,
                         destinationSlice: 0, destinationLevel: 0, destinationOrigin: .init(x: 0, y: 0, z: 0))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertEqual(command.status, .completed)
        }

        try finishUpload()
        XCTAssertTrue(try FlashRawNativeFiniteCheck.check(texture, cancellation: {}))
        let last = bytes.advanced(by: (height - 1) * stride / 2 + (width - 1) * 4)
        let faults: [(Int, UInt16)] = [(0, 0x7e01), (1, 0x7c00), (2, 0xfc00), (3, 0)]
        for (channel, invalid) in faults {
            let original = last[channel]
            last[channel] = invalid
            try finishUpload()
            XCTAssertFalse(try FlashRawNativeFiniteCheck.check(texture, cancellation: {}))
            last[channel] = original
        }
        try finishUpload()
        var cancellationChecks = 0
        XCTAssertThrowsError(try FlashRawNativeFiniteCheck.check(texture) {
            cancellationChecks += 1
            if cancellationChecks == 3 { throw CancellationError() }
        }) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(try FlashRawNativeFiniteCheck.check(texture, cancellation: {}))
    }
}
