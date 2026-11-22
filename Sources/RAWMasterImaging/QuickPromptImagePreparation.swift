import CoreImage
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers
import RAWMasterCore

public struct PreparedQuickPromptPixels: Sendable {
    public let input: RenderedPhoto
    public let selection, context: QuickPromptPixelRegion?
    public let matte: RenderedPhoto?
}

public enum QuickPromptImagePreparation {
    typealias Region = QuickPromptPixelRegion
    private static let srgb = PhotoRenderer.sRGB
    private static let srgbProfile = (srgb.copyICCData() as Data?).map {
        SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined()
    }
    private static let colorContext = CIContext(options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
                                                          .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
    private static let maskContext = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                                         .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])

    /// One deterministic aspect fit for submission and local inverse mapping. Coordinates are pixel edges.
    struct ModelLayout {
        let width, height: Int
        let scale, left, bottom: CGFloat
        var extent: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

        init(_ region: Region) {
            // Keep extreme panoramas in a padded canvas, without distorting the crop.
            let aspect = min(3, max(1.0 / 3, Double(region.width) / Double(region.height)))
            width = Int(floor(sqrt(1_048_576 * aspect) / 16)) * 16
            height = Int(floor(sqrt(1_048_576 / aspect) / 16)) * 16
            scale = min(CGFloat(width) / CGFloat(region.width), CGFloat(height) / CGFloat(region.height))
            left = (CGFloat(width) - CGFloat(region.width) * scale) / 2
            bottom = (CGFloat(height) - CGFloat(region.height) * scale) / 2
        }

        func transform(from rect: CGRect) -> CGAffineTransform {
            CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: left - rect.minX * scale, ty: bottom - rect.minY * scale)
        }
    }

    public static func prepare(basis: RenderedPhoto, selection: QuickPromptSelection, source: EditingSourceSnapshot,
                               recipe: DevelopmentRecipe, directory: URL) async throws -> PreparedQuickPromptPixels {
        try await renderingTask {
            try recipe.validate()
            guard directory.isFileURL else { throw EditingError.unsafePath }
            let fm = FileManager.default
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let scratch = directory.appending(path: ".prepare-" + UUID().uuidString, directoryHint: .isDirectory)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: scratch) }
            let file = scratch.appending(path: "basis.tiff")
            try fm.copyItem(at: basis.fileURL, to: file)
            let verified = try checked(file, expected: basis.artifact)
            guard verified.encoding == UTType.tiff.identifier, verified.bitDepth == 16,
                  let input = CIImage(contentsOf: file, options: [.applyOrientationProperty: false]) else { throw EditingError.invalidArtifact }
            let frame = Region(x: 0, y: 0, width: verified.pixelWidth, height: verified.pixelHeight)
            guard input.extent == rect(frame, height: frame.height) else { throw EditingError.invalidArtifact }
            // Local compositing writes codes into the original TIFF's stated colour space.
            guard selection == .whole || (verified.iccProfileSHA256 != nil && verified.iccProfileSHA256 == srgbProfile)
            else { throw EditingError.invalidProfile }
            var selected: Region?, matte: RenderedPhoto?
            switch selection {
            case .whole: break
            case .rectangle(let crop):
                selected = try pixels(crop, in: frame)
            case .mask(let id):
                let result = try freezeMask(id: id, source: source, recipe: recipe, frame: frame, destination: scratch.appending(path: "matte.png"))
                selected = result.0
                matte = result.1
            }
            if selected != nil {
                guard verified.iccProfileSHA256 == srgbProfile else { throw EditingError.invalidProfile }
                try verifyCompositeBasis(file, width: frame.width, height: frame.height)
            }
            let context = selected.map { expanded($0, in: frame) }
            let active = context ?? frame, roi = rect(active, height: frame.height), layout = ModelLayout(active)
            let modelImage = input.cropped(to: roi).transformed(by: layout.transform(from: roi), highQualityDownsample: true)
                .composited(over: CIImage(color: .white).cropped(to: layout.extent)).cropped(to: layout.extent)
            let temporary = scratch.appending(path: "input.png")
            try writeRGB8(modelImage, to: temporary)
            var artifact = try PhotoRenderer.inspect(temporary, sourceDepth: verified.sourceEffectiveBitDepth ?? verified.bitDepth)
            guard artifact.pixelWidth == layout.width, artifact.pixelHeight == layout.height, artifact.bitDepth == 8,
                  artifact.iccProfileSHA256 != nil else { throw EditingError.invalidArtifact }
            artifact.nativePixelWidth = frame.width; artifact.nativePixelHeight = frame.height
            artifact.alphaPolicy = .compositedWhite
            artifact.resamplingChain = basis.artifact.resamplingChain + ["\(QuickPromptEditSnapshot.currentMapping) context \(active.x),\(active.y) \(active.width)x\(active.height) aspect-fit \(layout.width)x\(layout.height)"]
            try artifact.validate()
            try Task.checkCancellation()
            let token = UUID().uuidString
            let inputURL = directory.appending(path: token + "-input.png")
            var finalMatte: RenderedPhoto?
            if let matte {
                let target = directory.appending(path: token + "-matte.png")
                try fm.moveItem(at: matte.fileURL, to: target)
                finalMatte = .init(fileURL: target, artifact: matte.artifact)
            }
            do { try fm.moveItem(at: temporary, to: inputURL) }
            catch { if let finalMatte { try? fm.removeItem(at: finalMatte.fileURL) }; throw error }
            return .init(input: .init(fileURL: inputURL, artifact: artifact), selection: selected, context: context, matte: finalMatte)
        }
    }

    /// Display the submitted PNG with a local-only overlay in exactly the model's fitted coordinate system.
    public static func confirmationThumbnail(_ prepared: PreparedQuickPromptPixels, maxPixel: Int = 640) async throws -> CGImage {
        try await renderingTask {
            guard (1...2048).contains(maxPixel),
                  var image = CIImage(contentsOf: prepared.input.fileURL, options: [.applyOrientationProperty: false])
            else { throw DevelopmentError.unreadable }
            if let selection = prepared.selection, let context = prepared.context {
                let height = prepared.input.artifact.nativePixelHeight
                let layout = ModelLayout(context), transform = layout.transform(from: rect(context, height: height))
                let coverage: CIImage
                if let matte = prepared.matte {
                    guard let frozen = CIImage(contentsOf: matte.fileURL, options: [.colorSpace: NSNull()]) else { throw DevelopmentError.unreadable }
                    coverage = frozen.cropped(to: rect(context, height: height)).transformed(by: transform)
                } else {
                    coverage = CIImage(color: .white).cropped(to: rect(selection, height: height)).transformed(by: transform)
                }
                let mask = coverage.composited(over: CIImage(color: .black).cropped(to: image.extent)).cropped(to: image.extent)
                let tint = CIImage(color: CIColor(red: 1, green: 0.12, blue: 0.08, alpha: 0.42)).cropped(to: image.extent).composited(over: image)
                image = tint.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: mask])
            }
            let factor = min(1, CGFloat(maxPixel) / max(image.extent.width, image.extent.height))
            let scaled = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor), highQualityDownsample: true)
            let area = CGRect(x: 0, y: 0, width: max(1, floor(scaled.extent.width)), height: max(1, floor(scaled.extent.height)))
            guard let cg = colorContext.createCGImage(scaled, from: area, format: .RGBA8, colorSpace: srgb, deferred: false)
            else { throw DevelopmentError.unreadable }
            return cg
        }
    }

    public static func compose(snapshot: QuickPromptEditSnapshot, output: AIEditOutput, destination: URL) async throws -> RenderedPhoto {
        try await renderingTask {
            guard (snapshot.mappingVersion ?? QuickPromptEditSnapshot.currentMapping) == QuickPromptEditSnapshot.currentMapping,
                  let selected = snapshot.selection, let context = snapshot.context,
                  (snapshot.maskID == nil) == (snapshot.matte == nil) else { throw EditingError.invalidArtifact }
            let basis = snapshot.basis.artifact, w = basis.pixelWidth, h = basis.pixelHeight
            try selected.validate(width: w, height: h); try context.validate(width: w, height: h)
            guard context.contains(selected), basis.encoding == UTType.tiff.identifier, basis.bitDepth == 16 else { throw EditingError.invalidArtifact }
            let protected = [snapshot.basis.url, output.fileURL] + [snapshot.matte?.url].compactMap { $0 }
            try RenderFiles.check(destination, protected: protected)
            let fm = FileManager.default, parent = destination.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            let scratch = parent.appending(path: ".compose-" + UUID().uuidString, directoryHint: .isDirectory)
            try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
            defer { try? fm.removeItem(at: scratch) }
            let stage = scratch.appending(path: "composed.tiff")
            try fm.copyItem(at: snapshot.basis.url, to: stage)
            let verified = try checked(stage, expected: basis)
            guard verified.iccProfileSHA256 != nil, verified.iccProfileSHA256 == srgbProfile else { throw EditingError.invalidProfile }
            let returned = scratch.appending(path: "returned").appendingPathExtension(output.fileURL.pathExtension)
            try fm.copyItem(at: output.fileURL, to: returned)
            let actual = try checked(returned, expected: output.artifact), layout = ModelLayout(context)
            guard actual.pixelWidth == layout.width, actual.pixelHeight == layout.height,
                  [UTType.png.identifier, UTType.jpeg.identifier, UTType.tiff.identifier].contains(actual.encoding),
                  let generated = CIImage(contentsOf: returned, options: [.applyOrientationProperty: false]),
                  generated.extent == layout.extent else { throw EditingError.invalidArtifact }
            let roi = rect(context, height: h)
            let restored = generated.transformed(by: layout.transform(from: roi).inverted(), highQualityDownsample: true)
            var mask: CIImage?
            if let matte = snapshot.matte {
                let copy = scratch.appending(path: "frozen-matte.png")
                try fm.copyItem(at: matte.url, to: copy)
                let actual = try checked(copy, expected: matte.artifact)
                guard actual.encoding == UTType.png.identifier, actual.bitDepth == 8, actual.pixelWidth == w, actual.pixelHeight == h,
                      let image = CIImage(contentsOf: copy, options: [.colorSpace: NSNull(), .applyOrientationProperty: false]) else { throw EditingError.invalidArtifact }
                mask = image
            }
            try compositeTIFF(at: stage, width: w, height: h, selection: selected, result: restored, matte: mask)
            var artifact = try PhotoRenderer.inspect(stage, sourceDepth: basis.sourceEffectiveBitDepth)
            artifact.nativePixelWidth = basis.nativePixelWidth; artifact.nativePixelHeight = basis.nativePixelHeight
            artifact.resamplingChain = basis.resamplingChain + ["\(QuickPromptEditSnapshot.currentMapping) inverse aspect-fit \(layout.width)x\(layout.height) to frozen context; linear sRGB local blend"]
            try artifact.validate()
            try Task.checkCancellation(); try RenderFiles.check(destination, protected: protected)
            try fm.moveItem(at: stage, to: destination)
            return .init(fileURL: destination, artifact: artifact)
        }
    }

    private static func checked(_ url: URL, expected: RenderArtifact) throws -> RenderArtifact {
        try expected.validate()
        let actual = try PhotoRenderer.inspect(url, sourceDepth: expected.sourceEffectiveBitDepth)
        let expectedEncoding = expected.encoding == "image/png" ? UTType.png.identifier : expected.encoding
        guard actual.sha256 == expected.sha256, actual.byteCount == expected.byteCount, actual.pixelWidth == expected.pixelWidth,
              actual.pixelHeight == expected.pixelHeight, actual.bitDepth == expected.bitDepth, actual.encoding == expectedEncoding,
              let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) == 1 else { throw EditingError.invalidArtifact }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        guard (properties?[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1 == 1 else { throw EditingError.invalidArtifact }
        return actual
    }

    private static func rect(_ region: Region, height: Int) -> CGRect {
        CGRect(x: region.x, y: height - region.y - region.height, width: region.width, height: region.height)
    }

    private static func pixels(_ crop: NormalizedCrop, in frame: Region) throws -> Region {
        guard [crop.x, crop.y, crop.width, crop.height].allSatisfy(\.isFinite), crop.x >= 0, crop.y >= 0,
              crop.width > 0, crop.height > 0, crop.x + crop.width <= 1.00000001, crop.y + crop.height <= 1.00000001
        else { throw DevelopmentError.invalidGeometry }
        let w = Double(frame.width), h = Double(frame.height)
        let x = Int(floor(crop.x * w)), y = Int(floor(crop.y * h))
        let right = min(frame.width, Int(ceil((crop.x + crop.width) * w)))
        let bottom = min(frame.height, Int(ceil((crop.y + crop.height) * h)))
        let result = Region(x: x, y: y, width: right - x, height: bottom - y)
        try result.validate(width: frame.width, height: frame.height)
        return result
    }

    private static func expanded(_ region: Region, in frame: Region) -> Region {
        let dx = Int(ceil(Double(region.width) * 0.15)), dy = Int(ceil(Double(region.height) * 0.15))
        let x = max(0, region.x - dx), y = max(0, region.y - dy)
        return .init(x: x, y: y, width: min(frame.width, region.x + region.width + dx) - x,
                     height: min(frame.height, region.y + region.height + dy) - y)
    }

    private static func writeRGB8(_ image: CIImage, to url: URL) throws {
        let w = Int(image.extent.width), h = Int(image.extent.height)
        var rgba = Data(count: w * h * 4), rgb = Data(count: w * h * 3)
        try rgba.withUnsafeMutableBytes { try render(image, from: image.extent, to: $0.baseAddress!, rowBytes: w * 4, format: .RGBA8, colorSpace: srgb) }
        rgb.withUnsafeMutableBytes { dest in rgba.withUnsafeBytes { src in
            let d = dest.bindMemory(to: UInt8.self), s = src.bindMemory(to: UInt8.self)
            for i in 0..<(w * h) { d[i*3] = s[i*4]; d[i*3+1] = s[i*4+1]; d[i*3+2] = s[i*4+2] }
        } }
        try png(rgb, width: w, height: h, channels: 3, colorSpace: srgb, to: url)
    }

    private static func png(_ bytes: Data, width: Int, height: Int, channels: Int, colorSpace: CGColorSpace, to url: URL) throws {
        guard let source = CGDataProvider(data: bytes as CFData),
              let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels, bytesPerRow: width * channels,
                               space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                               provider: source, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let target = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw DevelopmentError.invalidEncoding }
        CGImageDestinationAddImage(target, cg, nil)
        guard CGImageDestinationFinalize(target) else { throw DevelopmentError.invalidEncoding }
    }

    private static func render(_ image: CIImage, from rect: CGRect, to pointer: UnsafeMutableRawPointer,
                               rowBytes: Int, format: CIFormat, colorSpace: CGColorSpace?) throws {
        let target = CIRenderDestination(bitmapData: pointer, width: Int(rect.width), height: Int(rect.height), bytesPerRow: rowBytes, format: format)
        target.colorSpace = colorSpace
        target.alphaMode = format == .R8 ? .premultiplied : .unpremultiplied
        target.isFlipped = true; target.isDithered = false; target.isClamped = true
        let context = colorSpace == nil ? maskContext : colorContext
        let task = try context.startTask(toRender: image, from: rect, to: target, at: .zero)
        _ = try task.waitUntilCompleted()
    }

    private static func freezeMask(id: String, source: EditingSourceSnapshot, recipe: DevelopmentRecipe,
                                   frame: Region, destination: URL) throws -> (Region, RenderedPhoto) {
        guard let p = recipe.adjustmentsV3, let uuid = UUID(uuidString: id), let layer = p.masks.first(where: { $0.id == uuid }), layer.enabled, layer.opacity > 0
        else { throw DevelopmentError.invalidGeometry }
        let capture = try RenderFiles.capture(source)
        defer { try? FileManager.default.removeItem(at: capture.deletingLastPathComponent()) }
        let scope = DevelopmentMaskEngineV3.ScopeSelection(layer)
        let graph = try DevelopmentRendererV3.develop(capture, recipe: recipe, applyGeometry: false, context: colorContext,
                                                      scopeSelection: scope, checkCancellation: { try Task.checkCancellation() })
        guard var coverage = scope.coverage, coverage.extent == graph.image.extent else { throw DevelopmentError.invalidGeometry }
        if p.geometry.version == .legacyV1 || p.geometry.version == .legacyV2 {
            coverage = try PhotoRenderer.applyV2Geometry(coverage, DevelopmentRendererV3.legacyRecipe(p))
        } else {
            coverage = try DevelopmentGeometryEngineV3.apply(p.geometry, to: coverage)
        }
        if p.superResolution != nil { coverage = coverage.transformed(by: .init(scaleX: 2, y: 2)) }
        guard coverage.extent == rect(frame, height: frame.height) else { throw DevelopmentError.invalidGeometry }
        let pixelCount = frame.width.multipliedReportingOverflow(by: frame.height)
        guard !pixelCount.overflow else { throw DevelopmentError.invalidGeometry }
        var bytes = Data(count: pixelCount.partialValue)
        var minX = frame.width, minY = frame.height, maxX = -1, maxY = -1
        try bytes.withUnsafeMutableBytes { storage in
            for y in stride(from: 0, to: frame.height, by: 128) {
                let rows = min(128, frame.height - y)
                for x in stride(from: 0, to: frame.width, by: 1024) {
                    try Task.checkCancellation()
                    let tile = Region(x: x, y: y, width: min(1024, frame.width - x), height: rows)
                    let start = storage.baseAddress!.advanced(by: y * frame.width + x)
                    try render(coverage, from: rect(tile, height: frame.height), to: start, rowBytes: frame.width, format: .R8, colorSpace: nil)
                }
                for row in y..<(y + rows) {
                    let offset = row * frame.width
                    let values = UnsafeBufferPointer(start: storage.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self), count: frame.width)
                    guard let first = values.firstIndex(where: { $0 > 0 }), let last = values.lastIndex(where: { $0 > 0 }) else { continue }
                    minX = min(minX, first); maxX = max(maxX, last); minY = min(minY, row); maxY = row
                }
            }
        }
        guard maxX >= minX, maxY >= minY else { throw DevelopmentError.invalidGeometry }
        try png(bytes, width: frame.width, height: frame.height, channels: 1, colorSpace: CGColorSpaceCreateDeviceGray(), to: destination)
        let artifact = try PhotoRenderer.inspect(destination)
        return (.init(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1), .init(fileURL: destination, artifact: artifact))
    }

    /// RAWMaster's frozen TIFF contains uncompressed, interleaved, top-first RGB16(A) strips.
    /// Rewriting only selected integers preserves even hidden RGB beneath transparent pixels.
    private static func verifyCompositeBasis(_ url: URL, width: Int, height: Int) throws {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        let length = try file.seekToEnd()
        guard length > 8, length <= UInt64(Int.max),
              let address = mmap(nil, Int(length), PROT_READ, MAP_PRIVATE, file.fileDescriptor, 0),
              address != MAP_FAILED else { throw DevelopmentError.invalidEncoding }
        defer { munmap(address, Int(length)) }
        _ = try Strips(.init(start: address, count: Int(length)), width: width, height: height)
    }

    private static func compositeTIFF(at url: URL, width: Int, height: Int, selection: Region, result: CIImage, matte: CIImage?) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length > 8, length <= UInt64(Int.max),
              let address = mmap(nil, Int(length), PROT_READ | PROT_WRITE, MAP_SHARED, handle.fileDescriptor, 0),
              address != MAP_FAILED else { throw DevelopmentError.invalidEncoding }
        defer { munmap(address, Int(length)) }
        let storage = UnsafeMutableRawBufferPointer(start: address, count: Int(length))
        let tiff = try Strips(storage, width: width, height: height)
        for y in stride(from: selection.y, to: selection.y + selection.height, by: 96) {
            let rows = min(96, selection.y + selection.height - y)
            for x in stride(from: selection.x, to: selection.x + selection.width, by: 1024) {
                try Task.checkCancellation()
                let w = min(1024, selection.x + selection.width - x)
                let tile = rect(.init(x: x, y: y, width: w, height: rows), height: height)
                var weights: [UInt8] = []
                if let matte {
                    weights = .init(repeating: 0, count: w * rows)
                    try weights.withUnsafeMutableBytes { try render(matte, from: tile, to: $0.baseAddress!, rowBytes: w, format: .R8, colorSpace: nil) }
                    if weights.allSatisfy({ $0 == 0 }) { continue }
                }
                var pixels = [UInt16](repeating: 0, count: w * rows * 4)
                try pixels.withUnsafeMutableBytes {
                    try render(result, from: tile, to: $0.baseAddress!, rowBytes: w * 8, format: .RGBA16, colorSpace: srgb)
                }
                for row in 0..<rows {
                    let offset = tiff.rowOffset(row + y) + x * tiff.channels * 2
                    for column in 0..<w {
                        let i = row * w + column, weight = weights.isEmpty ? 255 : weights[i]
                        guard weight > 0 else { continue }
                        let base = offset + column * tiff.channels * 2
                        // Input to providers is opaque. Preserve the exact source alpha everywhere.
                        if tiff.channels == 4, tiff.read(base + 6) == 0 { continue }
                        for c in 0..<3 {
                            let index = base + c * 2, target = pixels[i * 4 + c]
                            let value = weight == 255 ? target : blend(tiff.read(index), target, weight)
                            tiff.write(value, at: index)
                        }
                    }
                }
            }
        }
        try handle.synchronize()
    }

    private static func blend(_ original: UInt16, _ changed: UInt16, _ mask: UInt8) -> UInt16 {
        func linear(_ code: UInt16) -> Double {
            let value = Double(code) / 65535
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let amount = Double(mask) / 255
        let result = linear(original) * (1 - amount) + linear(changed) * amount
        let encoded = result <= 0.0031308 ? 12.92 * result : 1.055 * pow(result, 1 / 2.4) - 0.055
        return UInt16(clamping: Int((encoded * 65535).rounded()))
    }

    private struct Strips {
        let storage: UnsafeMutableRawBufferPointer
        let little: Bool
        let offsets: [Int]
        let width, rowsPerStrip, channels: Int

        init(_ bytes: UnsafeMutableRawBufferPointer, width: Int, height: Int) throws {
            guard bytes.count >= 8 else { throw DevelopmentError.invalidEncoding }
            let little = bytes[0] == 73 && bytes[1] == 73
            guard little || (bytes[0] == 77 && bytes[1] == 77) else { throw DevelopmentError.invalidEncoding }
            func number(_ at: Int, _ size: Int) throws -> Int {
                guard at >= 0, at <= bytes.count - size else { throw DevelopmentError.invalidEncoding }
                var result = 0
                for i in 0..<size { result |= Int(bytes[at + (little ? i : size - 1 - i)]) << (8 * i) }
                return result
            }
            guard try number(2, 2) == 42 else { throw DevelopmentError.invalidEncoding }
            let directory = try number(4, 4), count = try number(directory, 2)
            guard (1...512).contains(count), directory + 2 + count * 12 + 4 <= bytes.count else { throw DevelopmentError.invalidEncoding }
            let requested: Set<Int> = [256,257,258,259,262,273,274,277,278,279,284,338,339]
            var tags = [Int: [Int]]()
            for i in 0..<count {
                let entry = directory + 2 + i * 12, tag = try number(entry, 2)
                guard requested.contains(tag) else { continue }
                let type = try number(entry + 2, 2), n = try number(entry + 4, 4)
                guard tags[tag] == nil, type == 3 || type == 4, n > 0, n <= max(height, 4) else { throw DevelopmentError.invalidEncoding }
                let size = type == 3 ? 2 : 4
                let start = n * size <= 4 ? entry + 8 : try number(entry + 8, 4)
                guard start <= bytes.count - n * size else { throw DevelopmentError.invalidEncoding }
                tags[tag] = try (0..<n).map { try number(start + $0 * size, size) }
            }
            let channels = tags[277]?.first ?? 1, rows = tags[278]?.first ?? height
            guard tags[256] == [width], tags[257] == [height], [3,4].contains(channels), tags[258] == Array(repeating: 16, count: channels),
                  (tags[259] ?? [1]) == [1], tags[262] == [2], (tags[274] ?? [1]) == [1], (tags[284] ?? [1]) == [1],
                  channels == 3 || tags[338] == [2], tags[339]?.allSatisfy({ $0 == 1 }) ?? true,
                  rows > 0, let offsets = tags[273], let counts = tags[279], offsets.count == (height + rows - 1) / rows,
                  counts.count == offsets.count else { throw DevelopmentError.invalidEncoding }
            for i in offsets.indices {
                let required = min(rows, height - rows * i) * width * channels * 2
                guard counts[i] >= required, offsets[i] >= 8, offsets[i] <= bytes.count - counts[i] else { throw DevelopmentError.invalidEncoding }
            }
            self.storage = bytes; self.width = width; self.offsets = offsets; self.channels = channels
            self.rowsPerStrip = rows; self.little = little
        }

        func rowOffset(_ y: Int) -> Int { offsets[y / rowsPerStrip] + (y % rowsPerStrip) * width * channels * 2 }

        func read(_ at: Int) -> UInt16 {
            let v = storage.loadUnaligned(fromByteOffset: at, as: UInt16.self)
            return little ? UInt16(littleEndian: v) : UInt16(bigEndian: v)
        }

        func write(_ value: UInt16, at offset: Int) {
            storage[offset] = little ? UInt8(truncatingIfNeeded: value) : UInt8(value >> 8)
            storage[offset + 1] = little ? UInt8(value >> 8) : UInt8(truncatingIfNeeded: value)
        }
    }
}
