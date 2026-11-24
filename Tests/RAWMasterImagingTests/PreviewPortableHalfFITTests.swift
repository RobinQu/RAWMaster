import CoreImage
import Metal
import RAWMasterCore
import XCTest
@testable import RAWMasterImaging

final class PreviewPortableHalfFITTests: XCTestCase {
    private var manualLevels: DevelopmentAdjustmentsV3 {
        var recipe = DevelopmentAdjustmentsV3()
        recipe.rawDecoder = .flashRaw031
        recipe.levels = .init(enabled: true, luminance: .manual(.init(
            black: 0.05, shadows: 0.20, midtones: 0.49, highlights: 0.49,
            white: 0.96, outputBlack: 0.04, outputWhite: 0.95)))
        return recipe
    }

    func testRequiresAnIsolatedCurvesOrLevelsRecipe() {
        let manual = manualLevels
        XCTAssertTrue(PreviewPortableHalfFIT.supports(manual))
        XCTAssertFalse(PreviewPortableHalfFIT.supports(manual.neutralForSameSource))

        var recipe = manual.neutralForSameSource
        recipe.curves = .init(enabled: true, rgb: .init(inputBlack: 0.02, inputWhite: 0.98))
        XCTAssertTrue(PreviewPortableHalfFIT.supports(recipe))
        recipe.curves.refineSaturation = 1
        XCTAssertFalse(PreviewPortableHalfFIT.supports(recipe))

        recipe = manual
        recipe.color = .init(enabled: true, saturation: 0.06)
        XCTAssertFalse(PreviewPortableHalfFIT.supports(recipe))
        recipe = manual
        recipe.geometry.flipHorizontal = true
        XCTAssertFalse(PreviewPortableHalfFIT.supports(recipe))
        recipe = manual
        recipe.rawDecoder = nil
        XCTAssertFalse(PreviewPortableHalfFIT.supports(recipe))
    }

    func testRevocationDrainsNativeHalfAndAnIndependentRequestCanRetry() throws {
        try verifyWithdrawalAndRetry(params: manualLevels, maskTone: nil)
    }

    private func colorWheels() -> DevelopmentAdjustmentsV3 {
        var p = manualLevels.neutralForSameSource
        let wheel = DevelopmentGradingWheel(hueDegrees: 28, saturation: 26, luminance: -9)
        let grading = DevelopmentColorGrading(shadows: wheel, blending: 27)
        p.legacyBasis = .init(version: .v2, color: .init(grading: grading))
        return p
    }

    func testRequiresAnIsolatedColorWheelRecipe() {
        let original = colorWheels()
        XCTAssertNotNil(PreviewPortableGrading(original))
        let excluded: [(inout DevelopmentAdjustmentsV3) -> Void] = [
            { $0.legacyBasis?.exposureEV = 1 }, { $0.legacyBasis?.color?.grading = .init() },
            { $0.legacyBasis?.color?.tones.contrast = 10 }, { $0.levels = self.manualLevels.levels },
            { $0.geometry.flipHorizontal = true }, { $0.rawDecoder = nil },
        ]
        for change in excluded {
            var p = original
            change(&p)
            XCTAssertNil(PreviewPortableGrading(p))
        }
    }

    func testColorWheelWithdrawalDrainsNativeHalfBeforeRetry() throws {
        let p = colorWheels()
        try verifyWithdrawalAndRetry(params: p, maskTone: nil, grading: XCTUnwrap(PreviewPortableGrading(p)))
    }

    private var frozenTone: DevelopmentAdjustmentsV3 {
        var p = manualLevels.neutralForSameSource
        p.masks = [.init(kind: .radial, feather: 0, adjustments: .init(hue: -0.21))]
        return p
    }

    func testFrozenCoverageRequiresOneOriginalRadialControl() throws {
        let original = frozenTone
        let tone = try XCTUnwrap(PreviewPortableMaskTone(original))
        XCTAssertEqual(tone.layer.id, original.masks[0].id)
        XCTAssertEqual(tone.control, "hue")
        XCTAssertEqual(tone.amount, -0.21)

        let excluded: [(inout DevelopmentAdjustmentsV3) -> Void] = [
            { $0.masks[0].kind = .linear }, { $0.masks[0].feather = 0.001 },
            { $0.masks[0].inverted = true }, { $0.masks[0].opacity = 0.99 },
            { $0.masks[0].adjustments.fineAdjustment = true },
            { $0.masks[0].adjustments.exposure = 0.1 }, { $0.masks.append(.init(kind: .radial)) },
            { $0.color = .init(enabled: true, saturation: 0.02) }, { $0.geometry.flipHorizontal = true },
            { $0.rawDecoder = nil }
        ]
        for change in excluded {
            var p = original
            change(&p)
            XCTAssertNil(PreviewPortableMaskTone(p))
        }
    }

    func testFrozenMaskWithdrawalDrainsCoverageAndNativeHalfBeforeRetry() throws {
        let p = frozenTone
        try verifyWithdrawalAndRetry(params: p, maskTone: XCTUnwrap(PreviewPortableMaskTone(p)))
    }

    private func verifyWithdrawalAndRetry(params: DevelopmentAdjustmentsV3, maskTone: PreviewPortableMaskTone?,
                                          grading: PreviewPortableGrading? = nil) throws {
        guard #available(macOS 27, *), let device = MTLCreateSystemDefaultDevice(),
              let raw = ProcessInfo.processInfo.environment["RAWMASTER_PREVIEW_BENCHMARK_RAW"] else {
            throw XCTSkip("Requires the RAW benchmark fixture and Metal on macOS 27")
        }
        let file = URL(fileURLWithPath: raw).resolvingSymlinksInPath()
        let digest = try RenderFiles.hash(file)
        let size = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let capture = try RenderFiles.verifiedPreviewCapture(.init(projectID: "035", assetID: "half-fit",
            contentSHA256: digest, byteCount: Int64(size), admissionFingerprint: "native-half", sourceLocation: file))
        defer { try? FileManager.default.removeItem(at: capture.url.deletingLastPathComponent()) }
        let native = try FlashRawImageFactory.nativePreviewImage(capture: capture.url, rawDetails: nil, retainNativeTexture: true)
        let extent = native.image.extent
        guard PreviewPortableHalfFIT.supports(extent.size, device: device) else {
            throw XCTSkip("Requires a qualified original RAW size and Metal device")
        }
        let pool = FlashRawCanonicalTexturePool()
        let key = FlashRawCanonicalTextureKey(sourceKey: digest, captureStamp: capture.stamp, contract: "native-half-fixture",
            width: Int(extent.width), height: Int(extent.height))
        let pin = try pool.acquireNative(key) { native }
        defer { pin.release() }
        let current = { try capture.requireCurrent(at: capture.url) }
        XCTAssertTrue(try pin.checkOpaqueUpload(pin.image, cancellation: current))

        let programs = PreviewPortableMetalPrograms()
        let telemetry = ImagePerformanceTelemetry.shared
        telemetry.reset()
        let operation = maskTone != nil ? "PreviewPortableMaskHalfFIT" :
            (grading != nil ? "PreviewPortableGradingHalfFIT" : "PreviewPortableHalfFIT")
        // After clear, after freezing coverage (when present), and after Rust submits its first four bands.
        for revocationCheck in maskTone == nil ? [4, 11] : [4, 7, 14] {
            var checks = 0
            let withdrawn = PreviewPortableHalfFIT(pin: pin, parameters: params, device: device,
                request: .init(programs: programs, revision: UInt64(revocationCheck), checkAuthority: {
                    try current()
                    if telemetry.snapshot().active.contains(where: { $0.operation == operation }) {
                        checks += 1
                        if checks == revocationCheck { throw CancellationError() }
                    }
                }), maskTone: maskTone, grading: grading)
            XCTAssertThrowsError(try withdrawn.makeHalf()) { XCTAssertTrue($0 is CancellationError, String(describing: $0)) }
            XCTAssertEqual(checks, revocationCheck)
            XCTAssertEqual(telemetry.snapshot().recent.first { $0.operation == operation }?.outcome, .cancelled)
            XCTAssertFalse(telemetry.snapshot().active.contains { $0.operation == operation })
        }

        let retry = PreviewPortableHalfFIT(pin: pin, parameters: params, device: device,
            request: .init(programs: programs, revision: 15, checkAuthority: current), maskTone: maskTone, grading: grading)
        let half = try XCTUnwrap(retry.makeHalf())
        XCTAssertEqual(half.extent, CGRect(x: 0, y: 0, width: extent.width / 2, height: extent.height / 2))
        XCTAssertTrue(telemetry.snapshot().recent.contains { $0.operation == operation && $0.outcome == .succeeded })
        pin.discard()
        XCTAssertThrowsError(try retry.requireCurrent())
    }
}
