import XCTest
import CoreImage
import ImageIO
import RAWMasterCore
@testable import RAWMasterImaging

final class QuickPromptImagePreparationTests: XCTestCase {
    private let color = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [.cacheIntermediates: false])

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func source(_ url: URL) throws -> EditingSourceSnapshot {
        let data = try Data(contentsOf: url)
        return .init(projectID: "prompt-test", assetID: "photo", contentSHA256: try RenderFiles.hash(url),
                     byteCount: Int64(data.count), admissionFingerprint: "test-fixture", sourceLocation: url)
    }

    /// Our native strip writer appends top-first little-endian RGBA16 after its IFD and ICC.
    /// Distinct channel values under zero alpha detect any color-managed round trip outside the ROI.
    private func basis(in root: URL, width: Int, height: Int) throws -> RenderedPhoto {
        let url = root.appending(path: "freeze.tiff")
        let extent = CGRect(x: 0, y: 0, width: width, height: height)
        let image = CIImage(color: .black).cropped(to: extent)
        try TIFF16Output.write(image, context: context, colorSpace: color, to: url, transport: .nativeTiles)
        var data = try Data(contentsOf: url)
        let start = data.count - width * height * 8
        for i in 0..<(width * height) {
            for c in 0..<4 {
                let v: UInt16 = c == 3 ? (i % 19 == 0 ? 0 : i % 5 == 0 ? 23451 : 65535) : UInt16((i * 31 + 1357 * c + 9421) % 65536)
                data[start + i*8 + 2*c] = UInt8(truncatingIfNeeded: v); data[start + i*8 + 2*c + 1] = UInt8(v >> 8)
            }
        }
        try data.write(to: url)
        return .init(fileURL: url, artifact: try PhotoRenderer.inspect(url))
    }

    private func returned(in root: URL, width: Int, height: Int) throws -> AIEditOutput {
        let url = root.appending(path: UUID().uuidString + ".png")
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        try context.writePNGRepresentation(of: CIImage(color: .red).cropped(to: rect), to: url, format: .RGBA8, colorSpace: color)
        return .init(fileURL: url, artifact: try PhotoRenderer.inspect(url))
    }

    private func snapshot(_ basis: RenderedPhoto, prepared: PreparedQuickPromptPixels, source: EditingSourceSnapshot, maskID: String? = nil) -> QuickPromptEditSnapshot {
        .init(basis: .init(artifact: basis.artifact, url: basis.fileURL),
              matte: prepared.matte.map { .init(artifact: $0.artifact, url: $0.fileURL) },
              selection: prepared.selection, context: prepared.context, maskID: maskID, work: .init(source: source), usesLiveDraft: false)
    }

    func testRectangleUsesFrozenTopLeftContextAndPreservesEveryProtectedUInt16IncludingHiddenRGB() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let w = 83, h = 63, base = try basis(in: root, width: w, height: h), original = try source(base.fileURL)
        let result = try await QuickPromptImagePreparation.prepare(basis: base,
            selection: .rectangle(.init(x: 0.19, y: 0.21, width: 0.29, height: 0.17)), source: original, recipe: .init(), directory: root)
        let selected = try XCTUnwrap(result.selection)
        XCTAssertEqual(selected, .init(x: 15, y: 13, width: 25, height: 11))
        XCTAssertEqual(result.context, .init(x: 11, y: 11, width: 33, height: 15))
        XCTAssertNil(result.matte)
        let input = result.input.artifact
        XCTAssertTrue((921_600...1_048_576).contains(input.pixelWidth * input.pixelHeight))
        XCTAssertEqual(input.pixelWidth % 16, 0); XCTAssertEqual(input.pixelHeight % 16, 0)
        let png = try Data(contentsOf: result.input.fileURL)
        XCTAssertEqual(png[24], 8); XCTAssertEqual(png[25], 2, "PNG IHDR must declare RGB8 with no alpha channel")
        let clean = PreparedQuickPromptPixels(input: result.input, selection: nil, context: nil, matte: nil)
        let cleanCG = try await QuickPromptImagePreparation.confirmationThumbnail(clean, maxPixel: 256)
        let markedCG = try await QuickPromptImagePreparation.confirmationThumbnail(result, maxPixel: 256)
        func rgb(_ cg: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                context.render(CIImage(cgImage: cg), toBitmap: $0.baseAddress!, rowBytes: 4,
                               bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: color)
            }
            return bytes
        }
        XCTAssertEqual(rgb(cleanCG, 1, 1), rgb(markedCG, 1, 1))
        XCTAssertNotEqual(rgb(cleanCG, cleanCG.width/2, cleanCG.height/2), rgb(markedCG, cleanCG.width/2, cleanCG.height/2))
        XCTAssertEqual(try RenderFiles.hash(result.input.fileURL), input.sha256, "The confirmation overlay is display-only")
        let model = try returned(in: root, width: input.pixelWidth, height: input.pixelHeight)
        let pending = snapshot(base, prepared: result, source: original)
        let final = try await QuickPromptImagePreparation.compose(snapshot: pending, output: model, destination: root.appending(path: "local.tiff"))
        let before = try Data(contentsOf: base.fileURL), after = try Data(contentsOf: final.fileURL)
        XCTAssertEqual(before.count, after.count)
        let start = before.count - w*h*8
        XCTAssertEqual(before.prefix(start), after.prefix(start))
        func code(_ bytes: Data, _ offset: Int) -> UInt16 { UInt16(bytes[offset]) | UInt16(bytes[offset+1]) << 8 }
        var changed = 0, protected = 0
        for y in 0..<h { for x in 0..<w {
            let p = start + (y*w+x)*8
            let selectedHere = selected.contains(.init(x: x, y: y, width: 1, height: 1))
            if selectedHere && code(before, p+6) > 0 {
                XCTAssertGreaterThan(code(after, p), 65_000); XCTAssertLessThan(code(after, p+2), 300)
                XCTAssertEqual(code(after, p+6), code(before, p+6)); changed += 1
            } else {
                XCTAssertEqual(after[p..<(p+8)], before[p..<(p+8)]); protected += 1
            }
        } }
        XCTAssertEqual(changed, 261); XCTAssertEqual(protected, 4_968)
        let wrong = try returned(in: root, width: input.pixelWidth - 16, height: input.pixelHeight)
        let rejected = root.appending(path: "wrong.tiff")
        do { _ = try await QuickPromptImagePreparation.compose(snapshot: pending, output: wrong, destination: rejected); XCTFail("Mismatched model geometry") }
        catch EditingError.invalidArtifact {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: rejected.path))
        XCTAssertEqual(try RenderFiles.hash(base.fileURL), original.contentSHA256)
    }

    func testWholePanoramaIsAspectFittedAndLocalInputsAreAbsent() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let frozen = try basis(in: root, width: 336, height: 21)
        let result = try await QuickPromptImagePreparation.prepare(basis: frozen, selection: .whole, source: source(frozen.fileURL), recipe: .init(), directory: root)
        XCTAssertNil(result.selection); XCTAssertNil(result.context); XCTAssertNil(result.matte)
        let input = result.input.artifact
        XCTAssertTrue((921_600...1_048_576).contains(input.pixelWidth * input.pixelHeight))
        let cg = try XCTUnwrap(CGImageSourceCreateWithURL(result.input.fileURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let image = CIImage(cgImage: cg)
        func sample(_ x: Int, _ y: Int) -> [UInt8] {
            var values = [UInt8](repeating: 0, count: 4)
            values.withUnsafeMutableBytes {
                context.render(image, toBitmap: $0.baseAddress!, rowBytes: 4, bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8, colorSpace: color)
            }
            return values
        }
        XCTAssertEqual(sample(input.pixelWidth/2, 2), [255,255,255,255])
        XCTAssertNotEqual(sample(input.pixelWidth/2, input.pixelHeight/2), [255,255,255,255])
    }

    func testSavedRadialOnEXIF8WithMirroredCropCreatesSoftSourceBoundMatteAndSameComposition() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let src = root.appending(path: "oriented.jpg")
        let extent = CGRect(x: 0, y: 0, width: 96, height: 74)
        let cg = try XCTUnwrap(context.createCGImage(CIImage(color: .gray).cropped(to: extent), from: extent, format: .RGBA8, colorSpace: color))
        let file = try XCTUnwrap(CGImageDestinationCreateWithURL(src as CFURL, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(file, cg, [kCGImagePropertyOrientation: 8] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(file))
        let original = try source(src)
        let center = DevelopmentSourcePoint(x: 0.25, y: 0.63)
        let layer = DevelopmentMaskLayerV3(name: "Scope", kind: .radial, center: center, radiusX: 0.11, radiusY: 0.13, feather: 0.65, opacity: 0.7)
        var params = DevelopmentAdjustmentsV3()
        params.masks = [layer]
        params.geometry = .init(version: .adjustV3, crop: .init(x: 0.1, y: 0.1, width: 0.85, height: 0.85), flipHorizontal: true)
        let recipe = DevelopmentRecipe(adjustmentsV3: params)
        let frozen = try await DevelopmentService().render(source: original, recipe: recipe, format: .tiff16, destination: root.appending(path: "basis.tiff"))
        let id = layer.id.uuidString
        let result = try await QuickPromptImagePreparation.prepare(basis: frozen, selection: .mask(id), source: original, recipe: recipe, directory: root)
        let matte = try XCTUnwrap(result.matte), selected = try XCTUnwrap(result.selection)
        XCTAssertEqual(matte.artifact.pixelWidth, frozen.artifact.pixelWidth); XCTAssertEqual(matte.artifact.pixelHeight, frozen.artifact.pixelHeight)
        XCTAssertGreaterThan(selected.x, frozen.artifact.pixelWidth / 2)
        XCTAssertGreaterThan(selected.y, frozen.artifact.pixelHeight / 3)
        let srcPNG = try Data(contentsOf: matte.fileURL)
        XCTAssertEqual(srcPNG[24], 8); XCTAssertEqual(srcPNG[25], 0)
        let maskCG = try XCTUnwrap(CGImageSourceCreateWithURL(matte.fileURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        let data = try XCTUnwrap(maskCG.dataProvider?.data) as Data
        XCTAssertTrue(data.contains(0)); XCTAssertTrue(data.contains { $0 > 0 && $0 < 240 })
        let input = result.input.artifact, returned = try returned(in: root, width: input.pixelWidth, height: input.pixelHeight)
        let snapshot = snapshot(frozen, prepared: result, source: original, maskID: id)
        let composed = try await QuickPromptImagePreparation.compose(snapshot: snapshot, output: returned, destination: root.appending(path: "mask-result.tiff"))
        let before = try XCTUnwrap(CGImageSourceCreateWithURL(frozen.fileURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) })
        let after = try XCTUnwrap(CGImageSourceCreateWithURL(composed.fileURL as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) })
        let bytes0 = try XCTUnwrap(before.dataProvider?.data) as Data, bytes1 = try XCTUnwrap(after.dataProvider?.data) as Data
        XCTAssertEqual(before.bitsPerPixel, after.bitsPerPixel)
        let stride = before.bitsPerPixel / 8
        var protected = 0, changed = 0
        for y in 0..<before.height { for x in 0..<before.width {
            let a = y*before.bytesPerRow + x*stride, b = y*after.bytesPerRow + x*stride
            if data[y*maskCG.bytesPerRow+x] == 0 {
                XCTAssertEqual(bytes0[a..<(a+stride)], bytes1[b..<(b+stride)]); protected += 1
            } else if bytes0[a..<(a+stride)] != bytes1[b..<(b+stride)] { changed += 1 }
        } }
        XCTAssertGreaterThan(protected, before.width * before.height / 2); XCTAssertGreaterThan(changed, 10)
    }
}
