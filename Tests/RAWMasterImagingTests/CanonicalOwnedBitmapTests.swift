import AppKit
import CoreImage
import Metal
import XCTest
@testable import RAWMasterImaging

final class CanonicalOwnedBitmapTests: XCTestCase {
    func testJoinedOwnedBitmapMatchesCanonicalPixelsAndCanRetryAfterRevocation() throws {
        guard MTLCreateSystemDefaultDevice()?.hasUnifiedMemory == true else {
            throw XCTSkip("A unified Metal GPU is required")
        }
        let size = CGSize(width: 2400, height: 1600)
        let bounds = CGRect(origin: .zero, size: size)
        let bottom = CIImage(color: CIColor(red: -0.01, green: 0.235, blue: 1.2, alpha: 1)).cropped(to: bounds)
        let top = CIImage(color: CIColor(red: 0.19, green: 0.08, blue: 0.4, alpha: 0.6))
            .cropped(to: CGRect(x: 30, y: 1100, width: 1601, height: 420))
        let graph = DevelopedV3Graph(image: top.composited(over: bottom), sourceDepth: 16,
            sourceSize: size, canonicalSize: size, graphDescriptor: "owned bitmap test")
        let context = DevelopmentColorEngineV3.makeContext()

        let standard = try V3PreviewMaterializer.materialize(graph, context: context, maxPixel: 2400)
        var checks = 0
        XCTAssertThrowsError(try V3PreviewMaterializer.materialize(graph, context: context, maxPixel: 2400,
            ownedBitmapAuthority: {
                checks += 1
                if checks == 3 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertEqual(checks, 3)

        let retried = try V3PreviewMaterializer.materialize(graph, context: context, maxPixel: 2400, ownedBitmapAuthority: {})
        context.clearCaches()
        XCTAssertEqual(standard.outputSize, retried.outputSize)
        XCTAssertEqual(standard.bytes, retried.bytes)
        XCTAssertEqual(try pixels(standard), try pixels(retried))
    }

    private func pixels(_ value: PreviewPixels) throws -> Data {
        let frame = DevelopmentPreviewFrame(frameID: UUID(), image: value.image, sessionID: .init(), sourceGeneration: 1,
            consumerID: .init(), revision: 1, quality: .settled, canonicalPixelSize: value.nativeSize,
            outputPixelSize: value.outputSize, outputKey: "owned bitmap test", approximate: false)
        var result = Data(count: Int(value.outputSize.width * value.outputSize.height) * 4)
        try result.withUnsafeMutableBytes { try frame.copyDisplayRGBA8(into: $0) }
        return result
    }
}
