import CoreImage
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

final class PhotoExportLayoutTests: XCTestCase {
    private let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context = CIContext(options: [.cacheIntermediates: false, .workingFormat: CIFormat.RGBAf.rawValue])
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("photo-layout-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func writeInput(_ name: String, size: CGSize = CGSize(width: 1200, height: 600),
                            date: String? = nil, camera: String = "Camera A", blue: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(name).appendingPathExtension("tiff")
        let bounds = CGRect(origin: .zero, size: size)
        let gradient = try XCTUnwrap(CIFilter(name: "CILinearGradient", parameters: [
            "inputPoint0": CIVector(x: 0, y: 0), "inputPoint1": CIVector(x: size.width, y: 0),
            "inputColor0": CIColor(red: blue ? 0.03 : 0.21, green: 0.06, blue: blue ? 0.41 : 0.02),
            "inputColor1": CIColor(red: blue ? 0.08 : 0.96, green: 0.10, blue: blue ? 0.97 : 0.06)])?.outputImage)
        let cg = try XCTUnwrap(context.createCGImage(gradient.cropped(to: bounds), from: bounds, format: .RGBA16, colorSpace: space))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, 1, nil))
        var exif: [CFString: Any] = [kCGImagePropertyExifFNumber: 2.8, kCGImagePropertyExifExposureTime: 1.0/250,
            kCGImagePropertyExifLensModel: "Prime 42", kCGImagePropertyExifFocalLength: 42,
            kCGImagePropertyExifISOSpeedRatings: [125], kCGImagePropertyExifBodySerialNumber: "private-serial"]
        if let date { exif[kCGImagePropertyExifDateTimeOriginal] = date + " 08:02:01" }
        let properties: [CFString: Any] = [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFModel: camera, kCGImagePropertyTIFFArtist: "Test Author",
                                              kCGImagePropertyTIFFCopyright: "Test Rights"],
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 37.2, kCGImagePropertyGPSLatitudeRef: "S",
                kCGImagePropertyGPSLongitude: 126.4, kCGImagePropertyGPSLongitudeRef: "W"]]
        CGImageDestinationAddImage(destination, cg, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return url
    }

    private func job(_ source: URL) throws -> (PhotoWork, EditingVersion, EditingArchive) {
        let bytes = try Data(contentsOf: source)
        let snapshot = EditingSourceSnapshot(projectID: "p", assetID: source.lastPathComponent,
            contentSHA256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
            byteCount: Int64(bytes.count), admissionFingerprint: "layout-test", sourceLocation: source)
        let work = PhotoWork(source: snapshot)
        let version = EditingVersion(id: work.originalVersionID, workID: work.id, parentVersionID: nil, kind: .original, source: snapshot)
        return (work, version, try EditingArchive(root: root.appendingPathComponent("archive"), protectedRoots: [source]))
    }

    private func export(_ source: URL, stem: String, format: PhotoRenderFormat = .png16, style: BuiltinPhotoStyle = .plain,
                        signature: String = "", limit: Int? = nil, policy: PhotoExportMetadataPolicy = .none,
                        gps: Bool = false) async throws -> URL {
        let (work, version, archive) = try job(source)
        let config = PhotoBatchExportConfiguration(format: format, maximumLongEdge: limit,
            layout: PhotoExportLayout(style: style, signature: signature), metadataPolicy: policy, includeGPS: gps)
        return try await PhotoBatchRenderExporter().export(work: work, version: version, archive: archive,
            directory: root, filename: stem, configuration: config)
    }

    private func image(_ url: URL) throws -> CIImage {
        try XCTUnwrap(CIImage(contentsOf: url))
    }

    private func properties(_ url: URL) throws -> [CFString: Any] {
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        return try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
    }

    private func pixelBytes(_ image: CIImage, in rect: CGRect) -> [UInt8] {
        let row = Int(rect.width) * 4
        var result = [UInt8](repeating: 0, count: row * Int(rect.height))
        result.withUnsafeMutableBytes { raw in context.render(image, toBitmap: raw.baseAddress!, rowBytes: row,
                                                             bounds: rect, format: .RGBA8, colorSpace: space) }
        return result
    }

    func testDateRendersEachInputsActualDateAndLeavesUntaggedPhotoClear() async throws {
        let a = try writeInput("one", date: "2024:07:22"), b = try writeInput("two", date: "2019:01:08")
        let missing = try writeInput("missing")
        let aURL = try await export(a, stem: "client.v2-0001", style: .date, limit: 640)
        let bURL = try await export(b, stem: "client.v2-0002", style: .date, limit: 640)
        let noDateURL = try await export(missing, stem: "no-date", style: .date, limit: 640)
        let plainURL = try await export(a, stem: "plain", limit: 640)
        XCTAssertEqual(aURL.lastPathComponent, "client.v2-0001.png")
        XCTAssertEqual(PhotoExportMetadata.read(from: a).date, "2024-07-22")
        XCTAssertEqual(PhotoExportMetadata.read(from: b).date, "2019-01-08")
        XCTAssertNil(PhotoExportMetadata.read(from: missing).date)
        let (first, second, blank, plain) = try (image(aURL), image(bURL), image(noDateURL), image(plainURL))
        let text = CGRect(x: 420, y: 10, width: 216, height: 45)
        XCTAssertNotEqual(pixelBytes(first, in: text), pixelBytes(second, in: text))
        XCTAssertNotEqual(pixelBytes(first, in: text), pixelBytes(plain, in: text))
        XCTAssertEqual(pixelBytes(blank, in: text), pixelBytes(plain, in: text))
        XCTAssertEqual(pixelBytes(first, in: CGRect(x: 20, y: 80, width: 600, height: 20)),
                       pixelBytes(plain, in: CGRect(x: 20, y: 80, width: 600, height: 20)))
    }

    func testMatsAndSplitColumnsUseTheirOwnPhotograph() async throws {
        XCTAssertEqual(PhotoExportAppearance(style: .paper).anchor, "bc")
        var saved = PhotoExportAppearance(style: .paper, signature: "First edition")
        saved.anchor = "bl"
        XCTAssertEqual(try JSONDecoder().decode(PhotoExportAppearance.self, from: JSONEncoder().encode(saved)).anchor, "bl")
        let warm = try writeInput("warm", date: "2026:04:12", camera: "A1")
        let cool = try writeInput("cool", date: "2025:04:12", camera: "Camera different", blue: true)
        let paperURL = try await export(warm, stem: "paper", style: .paper, signature: "North bank", limit: 640)
        let mistURL = try await export(warm, stem: "mist-warm", style: .mist, limit: 640)
        let mistBlueURL = try await export(cool, stem: "mist-blue", style: .mist, limit: 640)
        let splitURL = try await export(warm, stem: "split", style: .split, limit: 640)
        let otherSplit = try await export(cool, stem: "split-other", style: .split, limit: 640)
        let paper = try image(paperURL), mist = try image(mistURL), blue = try image(mistBlueURL), split = try image(splitURL)
        XCTAssertEqual(paper.extent.size, CGSize(width: 640, height: 427))
        XCTAssertEqual(mist.extent.size, CGSize(width: 512, height: 640))
        XCTAssertEqual(split.extent.size, CGSize(width: 640, height: 320))
        XCTAssertEqual(PhotoExportLayout(style: .split).pixelSize(for: CGSize(width: 1200, height: 600), maximumLongEdge: 640), split.extent.size)
        let corner = CGRect(x: 2, y: 2, width: 1, height: 1)
        let paperColor = pixelBytes(paper, in: corner), warmMat = pixelBytes(mist, in: corner), coolMat = pixelBytes(blue, in: corner)
        XCTAssertGreaterThan(paperColor[0], 230); XCTAssertGreaterThan(paperColor[1], 225)
        let caption = pixelBytes(paper, in: CGRect(x: 0, y: 22, width: 640, height: 49))
        let inkColumns = (0..<640).filter { x in (0..<49).contains { y in caption[(y * 640 + x) * 4] < 135 } }
        let firstInk = try XCTUnwrap(inkColumns.first), lastInk = try XCTUnwrap(inkColumns.last)
        XCTAssertEqual(Double(firstInk + lastInk) / 2, 320, accuracy: 5)
        XCTAssertGreaterThan(Int(warmMat[0]), Int(warmMat[2]) + 30)
        XCTAssertGreaterThan(Int(coolMat[2]), Int(coolMat[0]) + 30)
        let footer = pixelBytes(split, in: CGRect(x: 0, y: 10, width: 640, height: 35))
        let darkRGB = { (x: Int, y: Int) in footer[(y * 640 + x) * 4] < 130 }
        XCTAssertTrue((0..<35).contains { y in (313...315).contains { x in footer[(y * 640 + x) * 4] < 240 } })
        XCTAssertTrue((0..<35).contains { y in (6..<295).contains { darkRGB($0, y) } })
        XCTAssertTrue((0..<35).contains { y in (326..<620).contains { darkRGB($0, y) } })
        let leftColumn = CGRect(x: 5, y: 0, width: 285, height: 54)
        XCTAssertNotEqual(pixelBytes(split, in: leftColumn), pixelBytes(try image(otherSplit), in: leftColumn))
    }

    func testMetadataPoliciesReopenAllContainersWithGPSDepthICCAndFineSteps() async throws {
        let input = try writeInput("metadata", date: "2024:05:06")
        let cases: [(PhotoRenderFormat, PhotoExportMetadataPolicy, Bool, BuiltinPhotoStyle)] = [PhotoRenderFormat.jpeg8, .png16, .tiff16].flatMap { format in
            [(format, .none, true, .plain), (format, .rights, true, .plain), (format, .photo, false, .plain), (format, .photo, true, .sign)]
        }
        for (i, item) in cases.enumerated() {
            let (format, policy, gps, style) = item
            let url = try await export(input, stem: "meta-\(i)", format: format, style: style, signature: "Picture", policy: policy, gps: gps)
            let props = try properties(url), tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let geo = props[kCGImagePropertyGPSDictionary] as? [CFString: Any]
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFCopyright] as? String, policy == .none ? nil : "Test Rights")
            XCTAssertEqual(tiff?[kCGImagePropertyTIFFModel] as? String, policy == .photo ? "Camera A" : nil)
            XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber], "\(format) / \(policy)")
            if policy == .photo {
                XCTAssertEqual((exif?[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue ?? 0, 2.8, accuracy: 0.001)
            }
            if policy == .photo && gps {
                XCTAssertEqual(geo?[kCGImagePropertyGPSLatitudeRef] as? String, "S")
                XCTAssertEqual(geo?[kCGImagePropertyGPSLongitudeRef] as? String, "W")
            } else { XCTAssertNil(geo) }
            XCTAssertEqual((props[kCGImagePropertyDepth] as? NSNumber)?.intValue, format == .jpeg8 ? 8 : 16)
            let src = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
            let cg = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
            XCTAssertNotNil(cg.colorSpace?.copyICCData())
            if format != .jpeg8 {
                let rendered = try image(url)
                var words = [UInt16](repeating: 0, count: 1200 * 4)
                words.withUnsafeMutableBytes { raw in context.render(rendered, toBitmap: raw.baseAddress!, rowBytes: 1200 * 8,
                    bounds: CGRect(x: 0, y: 300, width: 1200, height: 1), format: .RGBA16, colorSpace: space) }
                let levels = Set(stride(from: 0, to: words.count, by: 4).map { words[$0] })
                XCTAssertGreaterThan(levels.count, 256)
            }
        }
    }

    func testSonyRAWCaptureOffsetSurvivesRealPhotoPolicy() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_TEST_SONY_A7III_ARW"] else {
            throw XCTSkip("Requires the public PIXLS.US Sony A7III RAW, archive entry 2414")
        }
        let source = URL(fileURLWithPath: path)
        let expectedHash = "250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f"
        XCTAssertEqual(try RenderFiles.hash(source), expectedHash)

        for format in [PhotoRenderFormat.jpeg8, .png16] {
            let policies: [PhotoExportMetadataPolicy] = format == .jpeg8 ? [.photo, .rights, .none] : [.photo, .none]
            var referencePixels: [UInt8]?
            for policy in policies {
                let output = try await export(source, stem: "raw-\(format)-\(policy)", format: format, limit: 512, policy: policy)
                let props = try properties(output)
                let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
                XCTAssertEqual(exif?[kCGImagePropertyExifDateTimeOriginal] as? String,
                               policy == .photo ? "2018:03:13 16:38:13" : nil, "\(format) / \(policy)")
                XCTAssertEqual(exif?[kCGImagePropertyExifOffsetTimeOriginal] as? String,
                               policy == .photo ? "+01:00" : nil, "\(format) / \(policy)")
                XCTAssertNil(exif?[kCGImagePropertyExifBodySerialNumber])
                XCTAssertNil(exif?[kCGImagePropertyExifMakerNote])
                XCTAssertNil(props[kCGImagePropertyGPSDictionary])
                XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 512)
                XCTAssertEqual((props[kCGImagePropertyDepth] as? NSNumber)?.intValue, format == .jpeg8 ? 8 : 16)
                let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
                let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
                XCTAssertNotNil(decoded.colorSpace?.copyICCData())
                let pixels = pixelBytes(try image(output), in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
                if let referencePixels { XCTAssertTrue(pixels == referencePixels, "\(format) / \(policy)") }
                else { referencePixels = pixels }
            }
        }
        XCTAssertEqual(try RenderFiles.hash(source), expectedHash)
    }

    func testOfflineArchivedSourceAndTiledOutputCarryTheirOwnTagsAndFullExtent() async throws {
        let input = try writeInput("wide-source", size: CGSize(width: 16432, height: 48), date: "2023:08:09", camera: "Archive")
        let (work, original, archive) = try job(input)
        let info = try await DevelopmentService().inspect(fileURL: input)
        let version = EditingVersion(workID: work.id, parentVersionID: original.id, kind: .external, source: original.source, artifact: info)
        let archived = try archive.publish(fileURL: input, version: version).version
        try FileManager.default.removeItem(at: input)
        let config = PhotoBatchExportConfiguration(format: .tiff16, layout: .init(style: .date), metadataPolicy: .photo)
        let url = try await PhotoBatchRenderExporter().export(work: work, version: archived, archive: archive,
                                                              directory: root, filename: "wide.archive", configuration: config)
        let props = try properties(url)
        XCTAssertEqual((props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 16432)
        XCTAssertEqual((props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, 48)
        XCTAssertEqual((props[kCGImagePropertyDepth] as? NSNumber)?.intValue, 16)
        XCTAssertEqual(PhotoExportMetadata.read(from: url).camera, "Archive")
        XCTAssertEqual(PhotoExportMetadata.read(from: url).date, "2023-08-09")
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
    }
    func testSharedAppearanceChangesRealOutputPixelsForLogoPlacementTransparencyAndSelectedFields() async throws {
        let source = try writeInput("portable-a", date: "2025:04:12")
        let other = try writeInput("portable-b", date: "2024:07:19")
        let logoCanvas = CGRect(x: 0, y: 0, width: 48, height: 16)
        let green = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 24, y: 0, width: 24, height: 16))
            .composited(over: CIImage(color: .clear).cropped(to: logoCanvas))
        let png = try XCTUnwrap(context.pngRepresentation(of: green, format: .RGBA8, colorSpace: space))
        let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
        var look = PhotoExportAppearance(style: .plain)
        look.mark = "logo"; look.logo = .init(sha256: sha, base64: png.base64EncodedString())
        look.ratio = "1:1"; look.frame = "solid"; look.paper = "#203040"; look.margin = 10
        look.stroke = 4; look.strokeColor = "#008cff"; look.anchor = "tl"; look.opacity = 100
        let encoded = try JSONEncoder().encode(look)
        let portable = try JSONDecoder().decode(PhotoExportAppearance.self, from: encoded)
        XCTAssertEqual(portable, look)
        func product(_ source: URL, _ stem: String, _ look: PhotoExportAppearance) async throws -> CIImage {
            let (work, version, archive) = try job(source)
            let config = PhotoBatchExportConfiguration(format: .png16, maximumLongEdge: 640, layout: .init(appearance: look))
            let output = try await PhotoBatchRenderExporter().export(work: work, version: version, archive: archive,
                directory: root, filename: stem, configuration: config)
            return try image(output)
        }
        let upper = try await product(source, "logo-upper", portable)
        look.anchor = "br"
        let lower = try await product(source, "logo-lower", look)
        look.mark = "off"
        let clean = try await product(source, "logo-hidden", look)
        XCTAssertEqual(upper.extent.size, CGSize(width: 640, height: 640))
        let topLeft = CGRect(x: 65, y: 380, width: 147, height: 62), bottomRight = CGRect(x: 435, y: 195, width: 130, height: 68)
        XCTAssertNotEqual(pixelBytes(upper, in: topLeft), pixelBytes(clean, in: topLeft))
        XCTAssertEqual(pixelBytes(lower, in: topLeft), pixelBytes(clean, in: topLeft))
        XCTAssertNotEqual(pixelBytes(lower, in: bottomRight), pixelBytes(clean, in: bottomRight))
        let transparentHalf = CGRect(x: 88, y: 405, width: 25, height: 12)
        XCTAssertEqual(pixelBytes(upper, in: transparentHalf), pixelBytes(clean, in: transparentHalf))
        let opaqueHalf = CGRect(x: 161, y: 405, width: 6, height: 6)
        XCTAssertGreaterThan(pixelBytes(upper, in: opaqueHalf)[1], 230)
        XCTAssertLessThan(pixelBytes(clean, in: opaqueHalf)[1], 130)
        look.logo = nil; look.mark = "exif"; look.place = "footer"; look.anchor = "bc"
        look.fields = ["camera"]
        let cameraA = try await product(source, "camera-a", look), cameraB = try await product(other, "camera-b", look)
        look.fields = ["date"]
        let dateA = try await product(source, "date-a", look), dateB = try await product(other, "date-b", look)
        let footer = CGRect(x: 70, y: 67, width: 500, height: 70)
        XCTAssertEqual(pixelBytes(cameraA, in: footer), pixelBytes(cameraB, in: footer))
        XCTAssertNotEqual(pixelBytes(dateA, in: footer), pixelBytes(dateB, in: footer))
        look.fit = "cover"
        XCTAssertEqual(PhotoExportLayout(appearance: look).pixelSize(for: CGSize(width: 4000, height: 100), maximumLongEdge: 1350),
                       CGSize(width: 148, height: 148))
    }
}
