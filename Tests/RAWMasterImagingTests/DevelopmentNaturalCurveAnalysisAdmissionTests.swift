import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentNaturalCurveAnalysisAdmissionTests: XCTestCase {
    private func recipe(_ algorithm: DevelopmentCurvesAlgorithmV3, enabled: Bool) -> DevelopmentRecipe {
        var curves = DevelopmentCurvesV3(enabled: enabled, algorithm: algorithm)
        curves.rgb.curve = .init(points: [.init(x: 0, y: 0), .init(x: 0.25, y: 0.45), .init(x: 1, y: 1)])
        return .init(adjustmentsV3: .init(curves: curves))
    }

    private func request(_ operation: DevelopmentAnalysisOperation, recipe: DevelopmentRecipe,
                         session: DevelopmentPreviewSessionID = .init(), generation: UInt64 = 1) throws -> DevelopmentAnalysisRequest {
        .init(preview: .init(sessionID: session, sourceGeneration: generation, consumerID: .init(), role: .primary,
                            revision: 1, recipe: recipe, quality: .settled, viewport: .init(maxPixel: 2400)),
              expectedRecipeFingerprint: try EditingFingerprint.of(recipe), stage: .workingImageBeforeGeometry,
              operation: operation)
    }

    private var legacyCurveOperations: [DevelopmentAnalysisOperation] {
        var operations: [DevelopmentAnalysisOperation] = [.automatic(.curves)]
        for channel in [DevelopmentCurveChannelV3ID.rgb, .red, .green, .blue] {
            for point in [DevelopmentCurvePickerPointV3.black, .midtone, .white, .addPoint] {
                operations.append(.curvePicker(channel: channel, point: point, sourcePoint: .init(x: 0.5, y: 0.5)))
            }
        }
        return operations
    }

    private func withActiveLevels(_ original: DevelopmentRecipe) throws -> DevelopmentRecipe {
        var recipe = original
        var p = try XCTUnwrap(recipe.adjustmentsV3)
        p.levels = .init(enabled: true, rgb: .manual(.init(black: 0.1, shadows: 0.25, midtones: 0.5,
            highlights: 0.75, white: 0.9, outputBlack: 0, outputWhite: 1)))
        recipe.adjustmentsV3 = p
        return recipe
    }

    func testNaturalEnabledAndDisabledAdmitPickerButRejectAutoWhileLegacyStillValidates() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for enabled in [false, true] {
            let natural = recipe(.naturalCubicGamma512LumaV1, enabled: enabled)
            let legacy = recipe(.legacyPCHIPV1, enabled: enabled)
            let naturalBytes = try encoder.encode(natural), legacyBytes = try encoder.encode(legacy)
            for operation in legacyCurveOperations {
                let candidate = try request(operation, recipe: natural)
                if case .curvePicker = operation {
                    XCTAssertNoThrow(try candidate.validate())
                    XCTAssertTrue(DevelopmentNaturalCurvePickerV1.isNatural(candidate))
                    XCTAssertEqual(try DevelopmentAnalysisEngine.samplingRecipe(candidate), natural)
                    let blocked = try XCTUnwrap(withActiveLevels(natural).adjustmentsV3)
                    XCTAssertThrowsError(try DevelopmentNaturalCurvePickerV1.validateAdmission(blocked, sourceIsRAW: false)) { error in
                        XCTAssertEqual(error as? DevelopmentV3Error, .unsupportedAnalysis)
                    }
                } else {
                    XCTAssertThrowsError(try candidate.validate()) { error in
                        XCTAssertEqual(error as? DevelopmentV3Error, .unsupportedAnalysis)
                    }
                }
                XCTAssertNoThrow(try request(operation, recipe: legacy).validate())
            }
            XCTAssertEqual(try encoder.encode(natural), naturalBytes)
            XCTAssertEqual(try encoder.encode(legacy), legacyBytes)
            XCTAssertFalse(String(decoding: legacyBytes, as: UTF8.self).contains("natural-cubic"))
        }
    }

    func testDirectNaturalAnalysisRejectsBeforeUnreadableCaptureAndDoesNotPublishCache() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("unused-natural-curves-" + UUID().uuidString).appendingPathExtension("tiff")
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: String(repeating: "a", count: 64),
            exifOrientation: 1, orientedWidth: 120, orientedHeight: 80)
        for enabled in [false, true] {
            for operation in legacyCurveOperations {
                var cache: DevelopmentAnalysisCacheEntry?
                let natural = recipe(.naturalCubicGamma512LumaV1, enabled: enabled)
                let input: DevelopmentRecipe
                if case .curvePicker = operation { input = try withActiveLevels(natural) }
                else { input = natural }
                let blocked = try request(operation, recipe: input)
                XCTAssertThrowsError(try DevelopmentAnalysisEngine.run(capture: missing, request: blocked,
                    sourceBinding: source, memoryHint: 512, cache: &cache)) { error in
                    XCTAssertEqual(error as? DevelopmentV3Error, .unsupportedAnalysis,
                                   "The metadata gate must precede source decoding and context work")
                }
                XCTAssertNil(cache)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    func testNaturalPickerServiceRequiresExactVersionFingerprintAndCommandAndRejectsActiveSuffixBeforeWorker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("natural-picker-service-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("source.png")
        let color = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
            space: color, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(red: 0.5, green: 0.4, blue: 0.3, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try XCTUnwrap(ctx.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let bytes = try Data(contentsOf: url)
        let source = EditingSourceSnapshot(projectID: "test", assetID: "natural-picker",
            contentSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(bytes.count), admissionFingerprint: "admitted", sourceLocation: url)
        let natural = recipe(.naturalCubicGamma512LumaV1, enabled: true)
        let op = DevelopmentAnalysisOperation.curvePicker(channel: .rgb, point: .black, sourcePoint: .init(x: 0.5, y: 0.5))
        for mode in 0..<7 {
            let service = DevelopmentPreviewService(analysisOverride: { request, binding in
                let p = request.preview
                let input = DevelopmentAnalysisBinding(sourceContentID: binding.sourceContentID,
                    sourceGeneration: p.sourceGeneration, expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage)
                var curves = try XCTUnwrap(p.recipe.adjustmentsV3?.curves)
                curves.rgb.inputBlack = 0.1
                if mode == 4 { curves.algorithm = .legacyPCHIPV1 }
                if mode == 5 { curves.rgb.inputBlack = 0.8; curves.rgb.inputWhite = 0.8000000000000001 }
                let purpose: DevelopmentAnalysisPurpose = mode == 3 ? .automatic(.curves) : .curvesPicker
                let commandBinding = mode == 6 ? DevelopmentAnalysisBinding(
                    sourceContentID: binding.sourceContentID, sourceGeneration: p.sourceGeneration + 1,
                    expectedRecipeFingerprint: request.expectedRecipeFingerprint, stage: request.stage) : input
                let mapping = try XCTUnwrap(p.recipe.adjustmentsV3?.geometry).mapping(sourceSize: binding.sourceSize)
                return .init(operationID: request.operationID, sessionID: p.sessionID, consumerID: p.consumerID,
                    revision: p.revision, role: p.role, quality: p.quality, actualRecipe: p.recipe, clientCorrelation: p.clientCorrelation,
                    binding: input, sourceBinding: binding, presentedRecipeFingerprint: request.presentedRecipeFingerprint, roi: request.roi,
                    samplingRecipeFingerprint: mode == 1 ? String(repeating: "0", count: 64) : try EditingFingerprint.of(p.recipe),
                    samplingVersion: mode == 0 ? "legacy-wrong-version" : DevelopmentNaturalCurvePickerV1.samplingVersion,
                    geometryMapping: mapping, value: .resolved(.init(binding: commandBinding, purpose: purpose, parameters: [.curves(curves)])))
            })
            let info = try await service.open(source: .raw(source))
            let blocked = try request(op, recipe: withActiveLevels(natural), session: info.id, generation: info.sourceGeneration)
            do { _ = try await service.analyze(blocked); XCTFail("Active downstream levels must fail before worker admission") }
            catch { XCTAssertEqual(error as? DevelopmentV3Error, .unsupportedAnalysis) }
            let blockedStats = await service.analysisStatistics()
            XCTAssertEqual(blockedStats.submitted, 0)
            let valid = try request(op, recipe: natural, session: info.id, generation: info.sourceGeneration)
            do {
                let result = try await service.analyze(valid)
                XCTAssertEqual(mode, 2, "Wrong sampling evidence must not be delivered")
                XCTAssertEqual(result.samplingRecipeFingerprint, try EditingFingerprint.of(natural))
                XCTAssertEqual(result.samplingVersion, DevelopmentNaturalCurvePickerV1.samplingVersion)
            } catch {
                XCTAssertNotEqual(mode, 2)
                XCTAssertEqual(error as? DevelopmentPreviewError, .invalidRequest)
            }
            await service.closeAll()
            let closed = await service.analysisStatistics()
            XCTAssertEqual(closed.submitted, 1); XCTAssertEqual(closed.active, 0); XCTAssertEqual(closed.pendingUser, 0)
        }
    }

    func testNaturalMetadataDoesNotBlockUnrelatedAutomaticHistogramOrSummaryOperations() throws {
        let operations: [DevelopmentAnalysisOperation] = [
            .histogram, .displayHistogram, .automatic(nil), .automatic(.light), .automatic(.color),
            .automatic(.levels), .summary(.light, amount: 0.5), .summary(.color, amount: 0.5),
            .summary(.blackAndWhite, amount: 0.5),
            .selectiveColorPicker(slot: .red, sourcePoint: .init(x: 0.5, y: 0.5))
        ]
        for enabled in [false, true] {
            let natural = recipe(.naturalCubicGamma512LumaV1, enabled: enabled)
            let originalFingerprint = try EditingFingerprint.of(natural)
            for operation in operations {
                let admitted = try request(operation, recipe: natural)
                XCTAssertNoThrow(try admitted.validate())
                XCTAssertEqual(try EditingFingerprint.of(admitted.preview.recipe), originalFingerprint)
            }
        }
    }
}
