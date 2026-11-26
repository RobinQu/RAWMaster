import XCTest
import AppKit
import CoreImage
import CryptoKit
import RAWMasterCore
@testable import RAWMasterImaging

final class DevelopmentSpektrafilmTests: XCTestCase {
    // Keep the order of the independently developed photographic reference strips explicit.
    private let looks: [DevelopmentPhotoFilterV3] = [
        .spektraPortra400Endura, .spektraVelvia100, .spektraVision250D2383,
        .spektraGold200UltraEndura, .spektraPortra800SupraEndura, .spektraEktar100Endura,
        .spektraProvia100F, .spektraEktachrome100, .spektraVision500T2383
    ]
    private let display = CGColorSpace(name: CGColorSpace.sRGB)!
    private let classicSHA = "0a8a0e9aa4fb7dacdf6ad20d12d5f24dda4132c4b7880acd7fab1c28fa6c61f9"
    private let filmSHA = "73c220dfae5e1a88abf219f48977c58ac7014f70f57ee7e77342b0c4a84644ed"

    private func fixtures() throws -> URL { try XCTUnwrap(Bundle.module.resourceURL).appending(path: "Fixtures") }

    private func context() -> CIContext {
        CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
                            .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
    }

    private func read(_ graph: CIImage, _ context: CIContext) throws -> [SIMD4<Float>] {
        var pixels = [SIMD4<Float>]()
        try DevelopmentLocalEngineV3.read(graph, rect: graph.extent, context: context) { pixels = Array($0) }
        return pixels
    }

    private func image(_ pixels: [SIMD4<Float>]) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: pixels.count * 16,
                size: CGSize(width: pixels.count, height: 1), format: .RGBAf, colorSpace: DevelopmentColorEngineV3.linearSRGB)
    }

    private func linear(_ code: Int) -> Float {
        let value = Double(code) / 255
        return Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4))
    }

    func testAllNineFilmEndpointsAgainstDirectScanAndContinuousLinearAmount() throws {
        struct Reference: Decodable { let inputSRGB8: [[Int]]; let expectedLinearRGB: [String: [[Float]]] }
        let url = try fixtures().appending(path: "spektrafilm-v1-reference.json")
        let reference = try JSONDecoder().decode(Reference.self, from: Data(contentsOf: url))
        let pixels = reference.inputSRGB8.map { SIMD4(linear($0[0]), linear($0[1]), linear($0[2]), 1) }
        let source = image(pixels), context = context()
        defer { context.clearCaches(); DevelopmentPhotoFilterResourceStore.shared.trimReady() }
        XCTAssertEqual(Set(looks), Set(DevelopmentPhotoFilterV3.allCases.filter(\.isSpektrafilm)))
        XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.stageIdentity(), DevelopmentPhotoFilterEngineV3.operatorVersion + "/catalog:" + classicSHA)
        for look in looks {
            let expected = try XCTUnwrap(reference.expectedLinearRGB[look.rawValue])
            for amount: Double in [0, 0.5, 25, 37.5, 50, 100] {
                let filter = DevelopmentFilterV3(enabled: true, selection: look, intensity: amount)
                let persisted = try JSONEncoder().encode(filter)
                XCTAssertEqual(try JSONDecoder().decode(DevelopmentFilterV3.self, from: persisted), filter)
                let actual = try DevelopmentPhotoFilterEngineV3.apply(filter, to: source)
                if amount == 0 { XCTAssertTrue(actual === source); continue }
                XCTAssertEqual(try DevelopmentPhotoFilterEngineV3.activeResourceIdentity(filter),
                               DevelopmentPhotoFilterEngineV3.spektrafilmOperatorVersion + "/catalog:" + filmSHA)
                let output = try read(actual, context)
                for i in pixels.indices {
                    for c in 0..<3 {
                        let desired = pixels[i][c] + Float(amount / 100) * (expected[i][c] - pixels[i][c])
                        XCTAssertEqual(output[i][c], desired, accuracy: 0.0007, "\(look), amount \(amount), swatch \(i), channel \(c)")
                    }
                    XCTAssertEqual(output[i].w, 1)
                }
            }
        }
    }

    func testFilmPreservesPremultipliedAlphaAndSignedHDRResidual() throws {
        let pixels: [SIMD4<Float>] = [.init(0.24, 0.46, 0.18, 1), .init(0.12, 0.23, 0.09, 0.5),
                                      .init(1, 0, 0.2, 1), .init(2, -0.25, 0.2, 1),
                                      .init(0, 0, 0, 0), .init(0.000001, 0, 0.000002, 0.000004)]
        let source = image(pixels), context = context()
        defer { context.clearCaches(); DevelopmentPhotoFilterResourceStore.shared.trimReady() }
        for look in looks {
            for amount: Double in [37.5, 100] {
                let filter = DevelopmentFilterV3(enabled: true, selection: look, intensity: amount)
                let output = try read(DevelopmentPhotoFilterEngineV3.apply(filter, to: source), context)
                XCTAssertEqual(output.map(\.w), pixels.map(\.w))
                for c in 0..<3 {
                    XCTAssertEqual(output[1][c], output[0][c] / 2, accuracy: 2e-6)
                    XCTAssertEqual(output[3][c] - output[2][c], pixels[3][c] - pixels[2][c], accuracy: 2e-6)
                }
                XCTAssertEqual(output[4], pixels[4])
                XCTAssertEqual(output[5], pixels[5])
            }
        }
    }

    func testNativeMetalPhotographsAgainstUpstreamDisplayReference() throws {
        struct Difference: Codable { let mean: Double; let p99: Int; let max: Int }
        var report = [String: [String: Difference]]()
        let ctx = context(), size = CGRect(x: 0, y: 0, width: 160, height: 240)
        defer { ctx.clearCaches(); DevelopmentPhotoFilterResourceStore.shared.trimReady() }
        func displayBytes(_ image: CIImage, _ extent: CGRect) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: Int(extent.width * extent.height) * 4)
            bytes.withUnsafeMutableBytes {
                ctx.render(image, toBitmap: $0.baseAddress!, rowBytes: Int(extent.width) * 4, bounds: extent, format: .RGBA8, colorSpace: display)
            }
            return bytes
        }
        let evidence = ProcessInfo.processInfo.environment["RAWMASTER_SPEKTRAFILM_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let evidence { try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true) }
        for photo in ["person", "snow"] {
            let url = try fixtures().appending(path: "Spektrafilm/\(photo)-catalog-v2.png")
            let strips = try XCTUnwrap(CIImage(contentsOf: url))
            XCTAssertEqual(strips.extent.size, CGSize(width: CGFloat(looks.count + 1) * size.width, height: size.height))
            let input = strips.cropped(to: size)
            var native = input
            for (index, look) in looks.enumerated() {
                let filter = DevelopmentFilterV3(enabled: true, selection: look)
                let output = try DevelopmentPhotoFilterEngineV3.apply(filter, to: input)
                let offset = CGFloat(index + 1) * size.width
                let expected = displayBytes(strips, size.offsetBy(dx: offset, dy: 0))
                let actual = displayBytes(output, size)
                var errors = (0..<actual.count).compactMap { $0 % 4 == 3 ? nil : abs(Int(actual[$0]) - Int(expected[$0])) }
                errors.sort()
                let diff = Difference(mean: Double(errors.reduce(0, +)) / Double(errors.count),
                                      p99: errors[errors.count * 99 / 100], max: errors.last!)
                report[photo, default: [:]][look.rawValue] = diff
                XCTAssertLessThan(diff.mean, 0.25, "\(photo), \(look)")
                XCTAssertLessThanOrEqual(diff.p99, 1, "\(photo), \(look)")
                XCTAssertLessThanOrEqual(diff.max, 2, "\(photo), \(look)")
                if evidence != nil {
                    // Evidence must not retain nine live 4 MiB LUT graphs under the shared 32 MiB cap.
                    let pixels = CIImage(bitmapData: Data(actual), bytesPerRow: Int(size.width) * 4,
                        size: size.size, format: .RGBA8, colorSpace: display)
                    native = pixels.transformed(by: .init(translationX: offset, y: 0)).composited(over: native)
                }
            }
            if let evidence {
                try ctx.writePNGRepresentation(of: native, to: evidence.appending(path: "\(photo)-native.png"), format: .RGBA8, colorSpace: display)
            }
        }
        if let evidence {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: evidence.appending(path: "native-vs-direct.json"), options: .atomic)
        }
    }

    func testDamagedFilmEndpointDoesNotAdvertiseOrRenderAndOtherCatalogStillWorks() throws {
        let fm = FileManager.default, bundled = try XCTUnwrap(DevelopmentPhotoFilterResourceStore.bundledRoot)
        let root = fm.temporaryDirectory.appending(path: UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let film = root.appending(path: "Spektrafilm")
        try fm.copyItem(at: bundled.appending(path: "Spektrafilm"), to: film)
        try fm.copyItem(at: bundled.appending(path: "catalog-v1.json"), to: root.appending(path: "catalog-v1.json"))
        for amount in DevelopmentPhotoFilterCatalog.intensities {
            let name = DevelopmentPhotoFilterCatalog.filename(.vivid, amount)
            try fm.copyItem(at: bundled.appending(path: name), to: root.appending(path: name))
        }
        let store = DevelopmentPhotoFilterResourceStore(resourceRoot: root)
        XCTAssertEqual(store.capabilities().filters, Set(looks + [.vivid, .original]))
        let broken = film.appending(path: DevelopmentPhotoFilterCatalog.filename(.spektraVelvia100, 100))
        try Data([0]).write(to: broken)
        let surviving = store.capabilities().filters
        XCTAssertFalse(surviving.contains(.spektraVelvia100))
        XCTAssertTrue(surviving.isSuperset(of: [.vivid, .spektraPortra400Endura, .spektraVision250D2383]))
        XCTAssertThrowsError(try store.pair(.init(enabled: true, selection: .spektraVelvia100)))
        XCTAssertEqual(try store.resourceVersion(for: .init(enabled: true, selection: .vivid)), classicSHA)
    }
}
