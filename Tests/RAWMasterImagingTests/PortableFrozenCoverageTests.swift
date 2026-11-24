import CoreImage
import CoreVideo
import Foundation
import IOSurface
import Metal
import RAWMasterCore
import RAWMasterImage
import XCTest
@testable import RAWMasterImaging

final class PortableFrozenCoverageTests: XCTestCase {
    private typealias Kernel = RAWMasterImageKernel
    private typealias Record = [String: Any]
    private let rawSHA = "8f96d2fd4fa0c76741ee09b486a4a5e17c8c893ce714060f2fe65eb34c891e1c"
    private let width = 2400, height = 1600

    private func capture(_ file: URL, hash: String) throws -> RenderFiles.VerifiedCapture {
        let size = try XCTUnwrap(file.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        return try RenderFiles.verifiedPreviewCapture(.init(projectID: "035", assetID: "frozen",
            contentSHA256: hash, byteCount: Int64(size), admissionFingerprint: "portable-frozen", sourceLocation: file))
    }

    func testSourceBindingTopRowAndRevokedAuthority() throws {
        let bitmap = try DevelopmentMaskBitmap(width: 2, height: 2, values: [255, 0, 64, 128])
        let png = try bitmap.png()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        try png.write(to: file, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: file) }
        let hash = DevelopmentSemanticMaskSnapshot.digest(png)
        let proof = try capture(file, hash: hash)
        defer { try? FileManager.default.removeItem(at: proof.url.deletingLastPathComponent()) }
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: hash, exifOrientation: 1, orientedWidth: 2, orientedHeight: 2)
        let snapshot = DevelopmentSemanticMaskSnapshot(source: source, target: .sky, generator: "fixture",
                                                      width: 2, height: 2, png: png)
        let layer = DevelopmentMaskLayerV3(kind: .subject, opacity: 0.5, subjectPNG: png, semanticSnapshot: snapshot)
        typealias Source = DevelopmentPortableFrozenCoverage.Source
        let input = try Source.rendered(proof, binding: source)
        let context = DevelopmentColorEngineV3.context
        func read(_ layers: [DevelopmentMaskLayerV3], input assigned: Source? = nil,
                  budget: Int = 16, check: () throws -> Void = {}) throws -> [Kernel.CoveragePlane] {
            try DevelopmentPortableFrozenCoverage.planes(for: layers, input: assigned ?? input,
                                                        context: context, byteBudget: budget, requireCurrent: check)
        }
        let plane = try XCTUnwrap(read([layer]).first)
        XCTAssertEqual(plane.id, layer.id.uuidString.lowercased())
        for (value, code) in zip(plane.values, [255, 0, 64, 128]) {
            XCTAssertEqual(value, Float(code) * 0.5 / 255, accuracy: 1e-6)
        }
        var inverted = layer
        inverted.inverted = true
        let inverse = try XCTUnwrap(read([inverted]).first)
        XCTAssertEqual(inverse.values[0], 0)
        XCTAssertEqual(inverse.values[1], 0.5)
        inverted.enabled = false
        XCTAssertEqual(try read([inverted]).first?.values, [0, 0, 0, 0])
        var foreign = source
        foreign.exifOrientation = 3
        XCTAssertThrowsError(try Source.rendered(proof, binding: foreign))
        foreign = source
        foreign.sourceContentID = String(repeating: "b", count: 64)
        XCTAssertThrowsError(try Source.rendered(proof, binding: foreign))
        foreign = source
        foreign.orientedWidth = 1
        XCTAssertThrowsError(try Source.rendered(proof, binding: foreign))

        let otherPNG = try DevelopmentMaskBitmap(width: 2, height: 2, values: [0, 255, 128, 64]).png()
        let otherFile = file.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".png")
        try otherPNG.write(to: otherFile, options: .withoutOverwriting)
        defer { try? FileManager.default.removeItem(at: otherFile) }
        foreign = source
        foreign.sourceContentID = DevelopmentSemanticMaskSnapshot.digest(otherPNG)
        let otherProof = try capture(otherFile, hash: foreign.sourceContentID)
        defer { try? FileManager.default.removeItem(at: otherProof.url.deletingLastPathComponent()) }
        XCTAssertThrowsError(try Source.rendered(otherProof, binding: source))
        let verifiedOtherImage = try Source.rendered(otherProof, binding: foreign)
        XCTAssertThrowsError(try read([layer], input: verifiedOtherImage))

        XCTAssertThrowsError(try read([layer, layer], budget: 32))
        XCTAssertThrowsError(try read([layer], budget: 15))
        var corrupt = layer
        corrupt.subjectPNG?.append(0)
        XCTAssertThrowsError(try read([corrupt]))
        var checkpoints = 0
        XCTAssertThrowsError(try read([layer], check: {
            checkpoints += 1
            if checkpoints == 3 { throw CancellationError() }
        })) { XCTAssertTrue($0 is CancellationError) }
    }

    // Frozen fixtures are the independently verified persisted 035 work-layer JSON and PNG receipts.
    func testOptInRealFlashRawTwoFrozenPlanes() throws {
        let env = ProcessInfo.processInfo.environment
        guard let directory = env["RAWMASTER_035_FROZEN_FIXTURES"], let out = env["RAWMASTER_035_FROZEN_OUTPUT"],
              let raw = env["RAWMASTER_035_FROZEN_RAW"] else { throw XCTSkip("Supply the frozen layers, Sony RAW and fresh output directory") }
        let fixtures = URL(fileURLWithPath: directory, isDirectory: true)
        let output = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let proof = try capture(URL(fileURLWithPath: raw).resolvingSymlinksInPath(), hash: rawSHA)
        defer { try? FileManager.default.removeItem(at: proof.url.deletingLastPathComponent()) }
        let source = DevelopmentLocalEditSourceBinding(sourceContentID: proof.contentSHA256, exifOrientation: 1,
                                                      orientedWidth: 9504, orientedHeight: 6336)
        let roles = ["sky", "subject"]
        let expected = ["88dcf52f4afc7c23e5ccabfa8abea0f214bd78fb743308daba2a080ff568b08b",
                        "2cc832d98dbf43aa3339af0fa2b2cd77c147175c603dc9c9e8d08f7f66038028"]
        var layers = try zip(roles, expected).map { role, sha in
            let layer = try JSONDecoder().decode(DevelopmentMaskLayerV3.self, from: Data(contentsOf: fixtures.appendingPathComponent(role + ".layer.json")))
            let frozen = try XCTUnwrap(layer.semanticSnapshot)
            let png = try Data(contentsOf: fixtures.appendingPathComponent(role + ".png"))
            XCTAssertEqual(layer.subjectPNG, png)
            XCTAssertEqual(frozen.source, source)
            XCTAssertEqual(frozen.target.rawValue, role)
            XCTAssertEqual(frozen.pngSHA256, sha)
            XCTAssertEqual(frozen.analysisDecoder, "flashraw-0.3.1-linear-srgb-bilinear")
            XCTAssertEqual(frozen.generator, role == "sky" ? "efficientvit-b2-ade20k-v1" : "vision-foreground-r1-v1")
            XCTAssertEqual(frozen.modelHashes, role == "sky" ? ["bdbe3961a13d75fe259f4bbc5d93dc8e4b5fe130c599acd6009ae1f382d6bc5d"] : [])
            return layer
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let context = CIContext(mtlDevice: device, options: [.workingColorSpace: DevelopmentColorEngineV3.linearSRGB,
            .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
        let input = try DevelopmentPortableFrozenCoverage.Source.flashRaw(proof, binding: source, maximumLongEdge: width)
        let image = input.image
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: width, height: height))
        let rgba = try pixels(image, context: context)
        let planes = try DevelopmentPortableFrozenCoverage.planes(for: layers, input: input,
            context: context, byteBudget: 2 * width * height * 4, requireCurrent: { try Task.checkCancellation() })
        let resources = try XCTUnwrap(DevelopmentPhotoFilterResourceStore.bundledRoot)
        let look = DevelopmentPhotoFilterV3.spektraVelvia100, amount = 37.5
        let filmFile = "Spektrafilm/spektraVelvia100-100.delta64.rgba32f"
        let filmSHA = try RenderFiles.hash(resources.appendingPathComponent(filmFile))
        XCTAssertEqual(filmSHA, "68009686b2f669f888bdb701cf1177ccd949ca9acb8a74f6ec3544a5ab3ca45d")
        let film = try DevelopmentPhotoFilterEngineV3.apply(.init(enabled: true, selection: look, intensity: amount), to: image)
        let ev = [0.75, -1.25]
        for i in layers.indices { layers[i].adjustments = .init(exposure: ev[i] / 2) }
        let legacy = try pixels(DevelopmentMaskEngineV3.apply(layers, to: film, context: context), context: context)
        let first: [Record] = [["id": "src", "op": "source"],
            ["id": "film", "op": "photo_filter", "image": "src", "look": look.rawValue, "amount": amount]]
        func recipe(_ version: Int, _ nodes: [Record], _ result: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["version": version, "working": "extended-linear-srgb-premul-f32",
                "nodes": nodes, "output": result] as Record, options: [.sortedKeys])
        }
        let w = UInt32(width), h = UInt32(height)
        let baseRecipe = try recipe(1, first, "film")
        let basePlan = try Kernel.RasterPlan(recipe: baseRecipe, resources: resources, backend: .cpu)
        let base = try basePlan.render(width: w, height: h, rgba: rgba)
        let nodes = first + [["id": planes[0].id, "op": "mask"], ["id": planes[1].id, "op": "mask"],
            ["id": "sky-ev", "op": "masked_exposure", "image": "film", "mask": planes[0].id, "ev": ev[0]],
            ["id": "subject-ev", "op": "masked_exposure", "image": "sky-ev", "mask": planes[1].id, "ev": ev[1]]]
        let graph = try recipe(2, nodes, "subject-ev")
        let graphURL = output.appendingPathComponent("recipe.json")
        try graph.write(to: graphURL, options: .withoutOverwriting)
        let cpuPlan = try Kernel.RasterPlan(recipe: graph, resources: resources, backend: .cpu)
        let cpu = try cpuPlan.render(width: w, height: h, rgba: rgba, coveragePlanes: Array(planes.reversed()))
        func file(_ name: String, _ values: [Float]) throws -> Record {
            let url = output.appendingPathComponent(name)
            try values.withUnsafeBytes { try Data($0).write(to: url, options: .withoutOverwriting) }
            return ["filename": name, "bytes": values.count * 4, "sha256": try RenderFiles.hash(url)]
        }
        var manifest: Record = ["width": width, "height": height, "sourceSHA256": proof.contentSHA256,
            "decoder": "FlashRaw 0.3.1 full-sensor GPU linear RGB F16 / bilinear; EXIF1 oriented preview sampled once",
            "layout": "top-down extended-linear-sRGB premultiplied RGBA32F/R32F little-endian",
            "film": ["look": look.rawValue, "amount": amount, "filename": filmFile, "sha256": filmSHA] as Record,
            "recipe": ["filename": graphURL.lastPathComponent, "sha256": try RenderFiles.hash(graphURL)],
            "frame": try file("source.rgba32fle", rgba), "base": try file("common-base.rgba32fle", base),
            "reference": try file("legacy-ci.rgba32fle", legacy), "cpu": try file("macos-cpu.rgba32fle", cpu)]
        manifest["planes"] = try planes.indices.map { i -> Record in
            var entry = try file(roles[i] + ".r32fle", planes[i].values)
            entry["id"] = planes[i].id
            entry["role"] = roles[i]
            entry["pngSHA256"] = expected[i]
            return entry
        }
        let gpuPlan = try Kernel.RasterPlan(recipe: graph, resources: resources, backend: .gpu)
        let gpu = try gpuPlan.render(width: w, height: h, rgba: rgba, coveragePlanes: planes)
        let metal = try borrowed(gpuPlan, rgba: rgba, planes: planes, device: device)
        let legacyBase = try pixels(film, context: context)
        let gpuBasePlan = try Kernel.RasterPlan(recipe: baseRecipe, resources: resources, backend: .gpu)
        let gpuBase = try gpuBasePlan.render(width: w, height: h, rgba: rgba)
        let metalBase = try borrowed(gpuBasePlan, rgba: rgba, planes: [], device: device)
        manifest["gpu"] = try file("macos-gpu.rgba32fle", gpu)
        manifest["metal"] = try file("macos-metal.rgba32fle", metal)
        manifest["cpuComparison"] = compare(cpu, reference: legacy, base: base, planes: planes)
        manifest["gpuComparison"] = compare(gpu, reference: cpu, base: gpuBase, planes: planes)
        manifest["metalComparison"] = compare(metal, reference: gpu, base: metalBase, planes: planes)
        manifest["legacyComparison"] = compare(legacy, reference: cpu, base: legacyBase, planes: planes)

        // Replay the same persisted sky and subject selections through the general V3 tone node.
        // The stored exposure amount is half the EV passed to masked_exposure.
        let toneNodes = Array(nodes.dropLast(2)) + [
            ["id": "sky-tone", "op": "mask_tone_v3", "image": "film", "mask": planes[0].id,
             "control": "exposure", "amount": ev[0] / 2],
            ["id": "subject-tone", "op": "mask_tone_v3", "image": "sky-tone", "mask": planes[1].id,
             "control": "exposure", "amount": ev[1] / 2]
        ]
        let toneGraph = try recipe(2, toneNodes, "subject-tone")
        let toneURL = output.appendingPathComponent("tone-recipe.json")
        try toneGraph.write(to: toneURL, options: .withoutOverwriting)
        manifest["frozenToneNode"] = try autoreleasepool { () throws -> Record in
            let cpuTonePlan = try Kernel.RasterPlan(recipe: toneGraph, resources: resources, backend: .cpu)
            let gpuTonePlan = try Kernel.RasterPlan(recipe: toneGraph, resources: resources, backend: .gpu)
            let cpuTone = try cpuTonePlan.render(width: w, height: h, rgba: rgba, coveragePlanes: Array(planes.reversed()))
            let gpuTone = try gpuTonePlan.render(width: w, height: h, rgba: rgba, coveragePlanes: planes)
            let metalTone = try borrowed(gpuTonePlan, rgba: rgba, planes: planes, device: device)
            return ["recipe": ["filename": toneURL.lastPathComponent, "sha256": try RenderFiles.hash(toneURL)],
                    "cpu": try file("tone-macos-cpu.rgba32fle", cpuTone),
                    "cpuComparison": compare(cpuTone, reference: legacy, base: base, planes: planes),
                    "gpuComparison": compare(gpuTone, reference: legacy, base: gpuBase, planes: planes),
                    "metalComparison": compare(metalTone, reference: gpuTone, base: metalBase, planes: planes)]
        }
        try proof.requireCurrent(at: proof.url)
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: output.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
    }

    private func pixels(_ image: CIImage, context: CIContext) throws -> [Float] {
        var result = [Float](repeating: .nan, count: width * height * 4)
        try result.withUnsafeMutableBytes { buffer in
            let dst = CIRenderDestination(bitmapData: try XCTUnwrap(buffer.baseAddress), width: width, height: height,
                                          bytesPerRow: width * 16, format: .RGBAf)
            dst.colorSpace = DevelopmentColorEngineV3.linearSRGB
            dst.alphaMode = .premultiplied
            dst.isFlipped = true
            dst.isClamped = false
            dst.isDithered = false
            _ = try context.startTask(toRender: image, from: image.extent, to: dst, at: .zero).waitUntilCompleted()
        }
        return result
    }

    private func compare(_ image: [Float], reference: [Float], base: [Float], planes: [Kernel.CoveragePlane]) -> Record {
        var finite = true, opaque = true
        var protected = 0, protectedDifferences = 0, skyOnly = 0, subjectOnly = 0, overlap = 0, changed = 0
        var maximum: Float = 0, normalized: Float = 0, analytical: Float = 0
        for i in 0..<(width * height) {
            let sky = planes[0].values[i], subject = planes[1].values[i]
            let offset = 4 * i
            let gain = Float(exp2(0.75 * Double(sky) - 1.25 * Double(subject)))
            opaque = opaque && image[offset + 3] == 1 && reference[offset + 3] == 1 && base[offset + 3] == 1
            if sky == 0 && subject == 0 { protected += 1 }
            else if sky == 0 { subjectOnly += 1 }
            else if subject == 0 { skyOnly += 1 }
            else { overlap += 1 }
            var different = false
            for c in 0..<4 {
                let actual = image[offset + c], expected = reference[offset + c], common = base[offset + c]
                finite = finite && actual.isFinite && expected.isFinite && common.isFinite
                let error = abs(actual - expected)
                maximum = max(maximum, error)
                normalized = max(normalized, error / max(1, abs(expected)))
                analytical = max(analytical, abs(actual - (c == 3 ? common : common * gain)) / max(1, abs(actual)))
                different = different || actual.bitPattern != common.bitPattern
            }
            if different {
                if sky == 0 && subject == 0 { protectedDifferences += 1 }
                else { changed += 1 }
            }
        }
        XCTAssertTrue(finite && opaque)
        XCTAssertEqual(protectedDifferences, 0)
        XCTAssertGreaterThan(min(protected, skyOnly, overlap, changed), 0)
        XCTAssertLessThanOrEqual(normalized, 0.00002)
        XCTAssertLessThanOrEqual(analytical, 0.00002)
        return ["maxAbs": maximum, "maxErrorDividedByMaxOneAbsReference": normalized,
            "maxNormalizedErrorVsAnalytical": analytical, "tolerance": 0.00002,
            "finite": finite, "alphaOne": opaque, "protected": protected, "protectedBitDifferences": protectedDifferences,
            "skyOnly": skyOnly, "subjectOnly": subjectOnly, "overlap": overlap, "coveredChanged": changed]
    }

    private func borrowed(_ plan: Kernel.RasterPlan, rgba: [Float], planes: [Kernel.CoveragePlane],
                          device: MTLDevice) throws -> [Float] {
        func texture(_ components: Int, initial: [Float]) throws -> MTLTexture {
            let bytes = 4 * components, row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * bytes)
            let format: OSType = components == 1 ? kCVPixelFormatType_OneComponent32Float : kCVPixelFormatType_128RGBAFloat
            let props: [CFString: Any] = [kIOSurfaceWidth: width, kIOSurfaceHeight: height,
                kIOSurfaceBytesPerElement: bytes, kIOSurfaceBytesPerRow: row, kIOSurfaceAllocSize: row * height,
                kIOSurfacePixelFormat: format]
            let surface = try XCTUnwrap(IOSurfaceCreate(props as CFDictionary))
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: components == 1 ? .r32Float : .rgba32Float,
                                                                      width: width, height: height, mipmapped: false)
            descriptor.usage = [.shaderRead, .shaderWrite]
            descriptor.storageMode = .shared
            descriptor.hazardTrackingMode = .tracked
            let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0))
            initial.withUnsafeBytes {
                texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                withBytes: $0.baseAddress!, bytesPerRow: width * bytes)
            }
            return texture
        }
        let input = try texture(4, initial: rgba)
        let output = try texture(4, initial: [Float](repeating: .nan, count: rgba.count))
        let masks = try planes.reversed().map { try Kernel.MetalCoveragePlane(id: $0.id, texture: texture(1, initial: $0.values)) }
        let program = try Kernel.MetalProgram(recipe: plan, device: device)
        try program.render(plan, input: input, coveragePlanes: masks, output: output, revision: 1, isCurrent: { $0 == 1 })
        var joined = [Float](repeating: .nan, count: rgba.count)
        joined.withUnsafeMutableBytes {
            output.getBytes($0.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        }
        return joined
    }
}
