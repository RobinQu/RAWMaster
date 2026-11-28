import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class NativeSharpenMeanTests: XCTestCase {
    func testQualificationRequiresTheOriginalSourceAndIsolatedStages() throws {
        var recipe = DevelopmentAdjustmentsV3()
        recipe.rawDecoder = .flashRaw031
        recipe.sharpen = .init(enabled: true, intensity: 0.75, radius: 1, detail: 0.25, masking: 0.6)
        XCTAssertEqual(PreviewNativeSharpenMean.plan(for: recipe)?.target, .photo)
        recipe.sharpen.visualiseMasking = true
        XCTAssertEqual(PreviewNativeSharpenMean.plan(for: recipe)?.target, .overlay)
        var unsupported = recipe
        unsupported.sharpen.radius = 1.5
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: unsupported))
        unsupported = recipe
        unsupported.geometry.flipHorizontal = true
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: unsupported))
        unsupported = recipe
        unsupported.rawDecoder = nil
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: unsupported))

        recipe.sharpen = .init()
        let layer = DevelopmentMaskLayerV3(kind: .radial, feather: 0, adjustments: .init(sharpness: 0.55))
        recipe.masks = [layer]
        XCTAssertEqual(PreviewNativeSharpenMean.plan(for: recipe)?.target, .layer(layer.id))
        recipe.masks[0].radiusX = Double.leastNonzeroMagnitude
        XCTAssertEqual(Float(recipe.masks[0].radiusX), 0)
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: recipe))
        recipe.masks = [layer]
        recipe.masks[0].adjustments.noiseReduction = 0.15
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: recipe))
        recipe.masks = [layer]
        recipe.masks[0].adjustments.sharpness = 1.01
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: recipe))
        recipe.masks = [layer, .init(kind: .radial, adjustments: .init(exposure: 0.2))]
        XCTAssertNil(PreviewNativeSharpenMean.plan(for: recipe))
    }

    func testRevocationAfterCoreImageTaskCreationDrainsBeforeRetry() throws {
        guard #available(macOS 27, *), let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory,
              let raw = ProcessInfo.processInfo.environment["RAWMASTER_PREVIEW_BENCHMARK_RAW"] else {
            throw XCTSkip("Requires the RAW benchmark fixture and a unified Metal device on macOS 27")
        }
        let file = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        let digest = try RenderFiles.hash(file)
        let size = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let capture = try RenderFiles.verifiedPreviewCapture(.init(projectID: "035", assetID: "sharpness",
            contentSHA256: digest, byteCount: Int64(size), admissionFingerprint: "sharpen-mean", sourceLocation: file))
        defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
        let native = try FlashRawImageFactory.nativePreviewImage(capture: capture.url, rawDetails: nil, retainNativeTexture: true)
        let extent = native.image.extent
        let pool = FlashRawCanonicalTexturePool()
        let key = FlashRawCanonicalTextureKey(sourceKey: digest, captureStamp: capture.stamp, contract: "sharpen-mean-fixture",
                                               width: Int(extent.width), height: Int(extent.height))
        let pin = try pool.acquireNative(key) { native }
        defer { pin.release() }
        var recipe = DevelopmentAdjustmentsV3()
        recipe.rawDecoder = .flashRaw031
        let layer = DevelopmentMaskLayerV3(kind: .radial, feather: 0, adjustments: .init(sharpness: 0.75))
        recipe.masks = [layer]
        let plan = try XCTUnwrap(PreviewNativeSharpenMean.plan(for: recipe))
        let context = CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
            .workingFormat: CIFormat.RGBAf.rawValue, .memoryTarget: 512, .cacheIntermediates: false])
        defer { context.clearCaches() }
        let telemetry = ImagePerformanceTelemetry.shared
        telemetry.reset()
        for revocationCheck in [1, 7] {
            var activeChecks = 0
            XCTAssertThrowsError(try PreviewNativeSharpenMean.prepare(plan: plan, pin: pin, source: pin.image, context: context,
                device: device, checkAuthority: {
                    try capture.requireCurrent(at: capture.url)
                    if telemetry.snapshot().active.contains(where: { $0.operation == "PreviewNativeSharpenMean" }) {
                        activeChecks += 1
                        if activeChecks == revocationCheck { throw CancellationError() }
                    }
                })) { XCTAssertTrue($0 is CancellationError, String(describing: $0)) }
            XCTAssertEqual(activeChecks, revocationCheck)
            XCTAssertFalse(telemetry.snapshot().active.contains(where: { $0.operation == "PreviewNativeSharpenMean" }))
        }
        let retry = try XCTUnwrap(PreviewNativeSharpenMean.prepare(plan: plan, pin: pin, source: pin.image, context: context,
            device: device, checkAuthority: { try capture.requireCurrent(at: capture.url) }))
        XCTAssertEqual(try retry.mean(for: pin.image, at: .layer(layer.id))?.extent, extent)
        XCTAssertNil(try retry.mean(for: pin.image, at: .photo))
        XCTAssertNil(try retry.mean(for: pin.image, at: .overlay))
        XCTAssertNil(try retry.mean(for: CIImage(color: .black).cropped(to: extent), at: .layer(layer.id)))
        if extent.width * extent.height > 32 * 1024 * 1024 {
            // The first retained R32 mean occupies more than half of the shared 256 MiB allowance.
            let second = try PreviewNativeSharpenMean.prepare(plan: plan, pin: pin, source: pin.image, context: context,
                device: device, checkAuthority: { try capture.requireCurrent(at: capture.url) })
            XCTAssertNil(second)
        }
        pin.discard()
        XCTAssertThrowsError(try retry.mean(for: pin.image, at: .layer(layer.id)))
    }
}
