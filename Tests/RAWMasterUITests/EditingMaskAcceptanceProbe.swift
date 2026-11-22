import CoreImage
import Darwin
import Darwin.Mach
import ImageIO
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

extension EditingInteractionPerformanceTests {
    static func maskProcessMemory() throws -> [String: UInt64] {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        var usage = rusage()
        guard result == KERN_SUCCESS, getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw CocoaError(.fileReadUnknown)
        }
        return ["residentBytes": UInt64(info.resident_size), "processPeakResidentBytes": UInt64(usage.ru_maxrss)]
    }

    @MainActor func measureSubjectMask(editing: EditingController, context: EditingInteractionContext,
                                       report: inout [String: Any]) async throws -> DevelopmentMaskLayerV3 {
        let session = editing.developmentSession
        let input = editing.developmentMaskInput
        let initial = session.recipe
        let source = try XCTUnwrap(session.source)
        let initialCounts = await input.candidateCounts()
        func countDelta() async -> [String: Int] {
            let counts = await input.candidateCounts()
            return ["exactHits": counts.exactCacheHits - initialCounts.exactCacheHits,
                    "freshNonBrushCandidates": counts.successfulGenerations - initialCounts.successfulGenerations]
        }
        // Completion is the publication of an adoptable Gray8 candidate. The overlay is drawn asynchronously.
        func request(_ target: DevelopmentSemanticTarget) async throws -> (DevelopmentMaskCandidate, Double) {
            let start = DispatchTime.now().uptimeNanoseconds
            input.begin(target, context: context)
            try await wait("local mask candidate", seconds: 60) { input.canAdopt || input.note != nil }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let candidate = try XCTUnwrap(input.candidate, input.note ?? "No candidate")
            XCTAssertEqual(candidate.source, source)
            XCTAssertEqual(candidate.target, target)
            XCTAssertEqual(session.recipe, initial)
            return (candidate, ms)
        }

        report["memoryBeforeSubject"] = try Self.maskProcessMemory()
        let (first, coldMs) = try await request(.subject)
        report["subjectFirstMs"] = coldMs
        report["subjectGenerator"] = first.generator
        report["orientedSource"] = ["width": source.orientedWidth, "height": source.orientedHeight, "exifOrientation": source.exifOrientation]
        report["coverageWidth"] = first.bitmap.width
        report["coverageHeight"] = first.bitmap.height
        report["coverageGray8SHA256"] = DevelopmentSemanticMaskSnapshot.digest(Data(first.bitmap.values))
        report["memoryAfterFirstSubject"] = try Self.maskProcessMemory()
        let firstCounts = await countDelta()
        report["maskCountersAfterFirst"] = firstCounts
        XCTAssertEqual(firstCounts, ["exactHits": 0, "freshNonBrushCandidates": 1])
        XCTAssertLessThanOrEqual(coldMs, 6_000)

        var warmMs: [Double] = []
        for _ in 0..<30 {
            input.cancel()
            let (repeated, duration) = try await request(.subject)
            warmMs.append(duration)
            report["subjectWarmSamplesMs"] = warmMs
            XCTAssertTrue(repeated.bitmap == first.bitmap, "Repeated subject coverage changed")
        }
        report["subjectWarm"] = statistics(warmMs)
        let warmCounts = await countDelta()
        report["maskCountersAfterWarm"] = warmCounts
        XCTAssertEqual(warmCounts, ["exactHits": 30, "freshNonBrushCandidates": 1])
        XCTAssertLessThanOrEqual(try XCTUnwrap(warmMs.max()), 250)
        input.cancel()
        let (background, backgroundMs) = try await request(.background)
        report["sameSourceFirstBackgroundMs"] = backgroundMs
        let backgroundCounts = await countDelta()
        report["maskCountersAfterBackground"] = backgroundCounts
        XCTAssertEqual(backgroundCounts, ["exactHits": 30, "freshNonBrushCandidates": 2])
        XCTAssertEqual(background.bitmap.width, first.bitmap.width)
        XCTAssertEqual(background.bitmap.height, first.bitmap.height)
        XCTAssertTrue(zip(first.bitmap.values, background.bitmap.values).allSatisfy { Int($0.0) + Int($0.1) == 255 })

        input.cancel()
        let (restored, restoredMs) = try await request(.subject)
        report["subjectAfterBackgroundMs"] = restoredMs
        let returnCounts = await countDelta()
        report["maskCountersAfterReturn"] = returnCounts
        XCTAssertEqual(returnCounts, ["exactHits": 31, "freshNonBrushCandidates": 2])
        XCTAssertTrue(restored.bitmap == first.bitmap, "Switching to background changed the original subject")
        let adoptedAt = DispatchTime.now().uptimeNanoseconds
        input.adopt(context: context)
        var masks = session.parameters.masks
        var layer = try XCTUnwrap(masks.last)
        let snapshot = try XCTUnwrap(layer.semanticSnapshot)
        XCTAssertEqual(snapshot.target, .subject)
        XCTAssertEqual(snapshot.source, source)
        try await wait("adopted mask settled draw", seconds: 90) {
            editing.previews.primary.frameRecipe == session.recipe &&
                editing.previews.primary.frame?.quality == .settled && editing.previews.primary.currentFrameWasDrawn
        }
        report["adoptToSettledDrawMs"] = Double(DispatchTime.now().uptimeNanoseconds - adoptedAt) / 1_000_000
        report["frozenPngSHA256"] = snapshot.pngSHA256
        // Exercise a visible local adjustment during export through the normal session transaction.
        layer.adjustments.exposure = 0.4
        masks[masks.count - 1] = layer
        try session.apply(.setMasks(masks), event: .init(context: context, control: .init(group: nil, name: "蒙版曝光"),
            nativeInput: .capture(control: "mask.exposure", phase: "discrete", nativeEvent: true)))
        try await wait("local adjustment settled draw", seconds: 90) {
            editing.previews.primary.frameRecipe == session.recipe &&
                editing.previews.primary.frame?.quality == .settled && editing.previews.primary.currentFrameWasDrawn
        }
        return layer
    }

    @MainActor static func exportReopenedMask(library: URL, workID: String, layer: DevelopmentMaskLayerV3,
                                              output: URL, report: inout [String: Any]) async throws {
        let store = try LibraryStore(databaseURL: library)
        let work = try store.photoWork(id: workID)
        let recipe = try XCTUnwrap(work.liveRecipe)
        let persisted = try XCTUnwrap(recipe.adjustmentsV3?.masks.first(where: { $0.id == layer.id }))
        XCTAssertEqual(persisted, layer)
        let snapshot = try XCTUnwrap(persisted.semanticSnapshot)
        try snapshot.validate(png: XCTUnwrap(persisted.subjectPNG))
        let destination = output.appending(path: "reopened-subject.tiff")
        let started = DispatchTime.now().uptimeNanoseconds
        let rendered = try await DevelopmentService().render(source: work.source, recipe: recipe, format: .tiff16,
                                                             destination: destination)
        report["reopenedRecipeExportMs"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        report["memoryAfterExport"] = try Self.maskProcessMemory()
        let reader = try XCTUnwrap(CGImageSourceCreateWithURL(rendered.fileURL as CFURL, nil))
        let frame = try XCTUnwrap(CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
        report["export"] = ["file": destination.lastPathComponent, "width": frame.width, "height": frame.height,
                            "bitsPerComponent": frame.bitsPerComponent, "sha256": try FileSafety.hash(rendered.fileURL)] as [String: Any]
        XCTAssertEqual(frame.width, snapshot.source.orientedWidth)
        XCTAssertEqual(frame.height, snapshot.source.orientedHeight)
        XCTAssertEqual(frame.bitsPerComponent, 16)

        var controlRecipe = recipe
        var parameters = try XCTUnwrap(recipe.adjustmentsV3)
        let index = try XCTUnwrap(parameters.masks.firstIndex(where: { $0.id == layer.id }))
        parameters.masks[index].enabled = false
        controlRecipe.adjustmentsV3 = parameters
        let control = try await DevelopmentService().render(source: work.source, recipe: controlRecipe, format: .tiff16,
            destination: output.appending(path: "disabled-layer-control.tiff"))
        report["controlTIFFSHA256"] = try FileSafety.hash(control.fileURL)
        let disabledDifference = try await Task.detached {
            try compareMaskExports(edited: rendered.fileURL, control: control.fileURL, layer: persisted)
        }.value
        let disabledUsesLegacy = try DevelopmentRendererV3.legacyEquivalent(controlRecipe) != nil
        let editedUsesLegacy = try DevelopmentRendererV3.legacyEquivalent(recipe) != nil
        report["toggleUsesSameRenderer"] = disabledUsesLegacy == editedUsesLegacy
        report["togglePixelComparison"] = disabledDifference

        // Disabling the last active V3 node can restore the historical renderer of a promoted work.
        // An enabled, zero-coverage copy retains the identical working prefix and node order.
        var difference = disabledDifference
        if disabledUsesLegacy != editedUsesLegacy {
            var matchedRecipe = recipe
            var matched = try XCTUnwrap(recipe.adjustmentsV3)
            let emptyBitmap = try DevelopmentMaskBitmap(width: snapshot.width, height: snapshot.height,
                values: [UInt8](repeating: 0, count: snapshot.width * snapshot.height))
            let emptyPNG = try emptyBitmap.png()
            matched.masks[index].subjectPNG = emptyPNG
            matched.masks[index].semanticSnapshot = .init(source: snapshot.source, target: snapshot.target,
                generator: snapshot.generator, modelHashes: snapshot.modelHashes, prompt: snapshot.prompt,
                width: snapshot.width, height: snapshot.height, png: emptyPNG)
            matchedRecipe.adjustmentsV3 = matched
            let samePrefix = try await DevelopmentService().render(source: work.source, recipe: matchedRecipe, format: .tiff16,
                destination: output.appending(path: "same-renderer-zero-coverage.tiff"))
            report["zeroCoverageTIFFSHA256"] = try FileSafety.hash(samePrefix.fileURL)
            difference = try await Task.detached {
                try compareMaskExports(edited: rendered.fileURL, control: samePrefix.fileURL, layer: persisted)
            }.value
        }
        report["pixelComparison"] = difference
        XCTAssertGreaterThan(difference["protectedPixels"] ?? 0, 0)
        XCTAssertEqual(difference["protectedMaximumRGBA16Difference"], 0)
        XCTAssertGreaterThan(difference["selectedPixels"] ?? 0, 0)
        XCTAssertGreaterThan(difference["selectedBrighterPixels"] ?? 0, 0)
        XCTAssertGreaterThan(difference["selectedRGBSumGain"] ?? 0, 0)
    }

    // The fresh work has identity geometry. A subject layer reads only its frozen Gray8 and opacity.
    private static func compareMaskExports(edited: URL, control: URL, layer: DevelopmentMaskLayerV3) throws -> [String: Int] {
        let options: [CIImageOption: Any] = [.colorSpace: NSNull(), .applyOrientationProperty: true]
        let adjusted = try XCTUnwrap(CIImage(contentsOf: edited, options: options))
        let reference = try XCTUnwrap(CIImage(contentsOf: control, options: options))
        guard adjusted.extent == reference.extent, layer.kind == .subject else { throw EditingError.invalidRecipe }
        let bounds = adjusted.extent
        let width = Int(bounds.width), height = Int(bounds.height)
        let selection = DevelopmentMaskEngineV3.ScopeSelection(layer)
        try selection.capture(CIImage(color: .white).cropped(to: bounds))
        let coverage = try XCTUnwrap(selection.coverage)
        let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(),
                                     .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
        let rowsPerTile = min(64, height)
        var pixels = [SIMD4<UInt16>](repeating: .zero, count: width * rowsPerTile)
        var comparison = pixels
        var matte = [Float](repeating: 0, count: width * rowsPerTile)
        var outside = 0, outsideMax = 0, inside = 0, brighter = 0, gain = 0
        for y in stride(from: 0, to: height, by: rowsPerTile) {
            try Task.checkCancellation()
            let rows = min(rowsPerTile, height - y)
            let rect = CGRect(x: bounds.minX, y: bounds.minY + CGFloat(y), width: CGFloat(width), height: CGFloat(rows))
            let rgbStride = width * MemoryLayout<SIMD4<UInt16>>.stride
            pixels.withUnsafeMutableBytes { ci.render(adjusted, toBitmap: $0.baseAddress!, rowBytes: rgbStride,
                bounds: rect, format: .RGBA16, colorSpace: nil) }
            comparison.withUnsafeMutableBytes { ci.render(reference, toBitmap: $0.baseAddress!, rowBytes: rgbStride,
                bounds: rect, format: .RGBA16, colorSpace: nil) }
            matte.withUnsafeMutableBytes { ci.render(coverage, toBitmap: $0.baseAddress!, rowBytes: width * MemoryLayout<Float>.stride,
                bounds: rect, format: .Rf, colorSpace: nil) }
            for i in 0..<(width * rows) {
                let a = pixels[i], b = comparison[i]
                if matte[i] == 0 {
                    outside += 1
                    if a != b {
                        for channel in 0..<4 { outsideMax = max(outsideMax, abs(Int(a[channel]) - Int(b[channel]))) }
                    }
                } else if matte[i] >= 0.5 {
                    inside += 1
                    let delta = Int(a.x) + Int(a.y) + Int(a.z) - Int(b.x) - Int(b.y) - Int(b.z)
                    gain += delta
                    if delta > 0 { brighter += 1 }
                }
            }
        }
        return ["protectedPixels": outside, "protectedMaximumRGBA16Difference": outsideMax, "selectedPixels": inside,
                "selectedBrighterPixels": brighter, "selectedRGBSumGain": gain]
    }
}
