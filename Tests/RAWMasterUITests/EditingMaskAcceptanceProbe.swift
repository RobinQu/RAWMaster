import Combine
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
        let source = try Self.required(session.source)
        func diagnostics() async throws -> DevelopmentMaskAnalysisDiagnostics {
            try Self.required(await input.analysisDiagnostics(for: source.sourceContentID), "Missing source-scoped mask statistics")
        }
        let initialCounts = await input.analysisDiagnostics(for: source.sourceContentID)
        func countDelta() async throws -> [String: Int] {
            let counts = try await diagnostics()
            return ["exactHits": counts.exactCacheHits - (initialCounts?.exactCacheHits ?? 0),
                    "freshNonBrushCandidates": counts.successfulGenerations - (initialCounts?.successfulGenerations ?? 0)]
        }
        // Completion is the publication of an adoptable Gray8 candidate. The overlay is drawn asynchronously.
        func request(_ target: DevelopmentSemanticTarget) async throws -> (DevelopmentMaskCandidate, Double) {
            var publishedAt: UInt64?
            let observer = input.$overlayRevision.dropFirst().sink { _ in
                if publishedAt == nil, input.canAdopt, input.candidate?.target == target, input.candidate?.source == source {
                    publishedAt = DispatchTime.now().uptimeNanoseconds
                }
            }
            defer { observer.cancel() }
            let start = DispatchTime.now().uptimeNanoseconds
            input.begin(target, context: context)
            try await wait("local mask candidate", seconds: 60) { input.canAdopt || input.note != nil }

            let candidate = try Self.required(input.candidate, input.note ?? "No candidate")
            guard candidate.source == source, candidate.target == target, session.recipe == initial,
                  let publishedAt, publishedAt >= start else { throw ProbeFailure("Candidate receipt, target or initial recipe mismatch") }
            return (candidate, Double(publishedAt - start) / 1_000_000)
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
        let firstCounts = try await countDelta()
        report["maskCountersAfterFirst"] = firstCounts
        Self.gate(firstCounts == ["exactHits":0,"freshNonBrushCandidates":1], "mask.freshFirstGeneration", &report)
        Self.gate(coldMs <= 6_000, "mask.coldAtMost6000ms", &report)
        let firstDiagnostics = try await diagnostics()
        report["maskAnalysisAfterFirst"] = Self.maskDiagnostics(firstDiagnostics)
        Self.gate(firstDiagnostics.visionRequests > (initialCounts?.visionRequests ?? 0), "mask.coldSubjectRanVision", &report)
        Self.gate(firstDiagnostics.sourceContentID == source.sourceContentID &&
            firstDiagnostics.exifOrientation == source.exifOrientation &&
            firstDiagnostics.orientedHeight == source.orientedHeight && firstDiagnostics.orientedWidth == source.orientedWidth,
            "mask.matchesEditorSourceCoordinates", &report)
        if session.parameters.rawDecoder == .flashRaw031 {
            Self.gate(firstDiagnostics.decoder == DevelopmentRAWDecoder.flashRaw031.rawValue &&
                firstDiagnostics.flashRawDecodes > (initialCounts?.flashRawDecodes ?? 0) &&
                firstDiagnostics.coreImageRawDecodes == (initialCounts?.coreImageRawDecodes ?? 0),
                "mask.usesSelectedFlashRawDecoder", &report)
        }

        var warmMs: [Double] = []
        for _ in 0..<30 {
            input.cancel()
            let (repeated, duration) = try await request(.subject)
            warmMs.append(duration)
            report["subjectWarmSamplesMs"] = warmMs
            Self.gate(repeated.bitmap == first.bitmap, "mask.warmCoverageUnchanged", &report)
        }
        report["subjectWarm"] = statistics(warmMs)
        let warmCounts = try await countDelta()
        report["maskCountersAfterWarm"] = warmCounts
        Self.gate(warmCounts == ["exactHits":30,"freshNonBrushCandidates":1], "mask.30ExactHitsOneGeneration", &report)
        Self.gate(try Self.required(warmMs.max()) <= 250, "mask.allWarmHitsAtMost250ms", &report)
        let warmDiagnostics = try await diagnostics()
        report["maskAnalysisAfterWarm"] = Self.maskDiagnostics(warmDiagnostics)
        Self.gate(warmDiagnostics.modelInvocations == firstDiagnostics.modelInvocations, "mask.warmHitsNoModelInvocations", &report)
        Self.gate(warmDiagnostics.flashRawDecodes == firstDiagnostics.flashRawDecodes &&
            warmDiagnostics.coreImageRawDecodes == firstDiagnostics.coreImageRawDecodes &&
            warmDiagnostics.imageIODecodes == firstDiagnostics.imageIODecodes, "mask.warmHitsNoDecode", &report)
        input.cancel()
        let (background, backgroundMs) = try await request(.background)
        report["sameSourceFirstBackgroundMs"] = backgroundMs
        let backgroundCounts = try await countDelta()
        report["maskCountersAfterBackground"] = backgroundCounts
        Self.gate(backgroundCounts == ["exactHits":30,"freshNonBrushCandidates":2], "mask.distinctBackgroundCandidate", &report)
        Self.gate(background.bitmap.width == first.bitmap.width && background.bitmap.height == first.bitmap.height &&
            zip(first.bitmap.values, background.bitmap.values).allSatisfy { Int($0.0) + Int($0.1) == 255 },
            "mask.backgroundComplementsSubject", &report)

        input.cancel()
        let (restored, restoredMs) = try await request(.subject)
        report["subjectAfterBackgroundMs"] = restoredMs
        let returnCounts = try await countDelta()
        report["maskCountersAfterReturn"] = returnCounts
        Self.gate(returnCounts == ["exactHits":31,"freshNonBrushCandidates":2], "mask.subjectReusedAfterBackground", &report)
        Self.gate(restored.bitmap == first.bitmap, "mask.restoredSubjectCoverageUnchanged", &report)
        report["maskAnalysisBeforeAdopt"] = Self.maskDiagnostics(try await diagnostics())
        let adoptedAt = DispatchTime.now().uptimeNanoseconds
        input.adopt(context: context)
        var masks = session.parameters.masks
        var layer = try Self.required(masks.last)
        let snapshot = try Self.required(layer.semanticSnapshot)
        Self.gate(snapshot.target == .subject && snapshot.source == source, "mask.adoptedSourceAndTarget", &report)
        let adopted = try await drawn(editing, recipe: session.recipe, quality: .settled, after: adoptedAt, label: "adopted mask settled draw")
        report["adoptToSettledDrawMs"] = try adopted.duration(since: adoptedAt)
        report["adoptDraw"] = adopted.evidence(start: adoptedAt)
        report["frozenPngSHA256"] = snapshot.pngSHA256
        // Exercise a visible local adjustment during export through the normal session transaction.
        layer.adjustments.exposure = 0.4
        masks[masks.count - 1] = layer
        let adjustedAt = DispatchTime.now().uptimeNanoseconds
        try session.apply(.setMasks(masks), event: .init(context: context, control: .init(group: nil, name: "蒙版曝光"),
            nativeInput: .capture(control: "mask.exposure", phase: "discrete", nativeEvent: true)))
        let adjusted = try await drawn(editing, recipe: session.recipe, quality: .settled, after: adjustedAt, label: "local adjustment settled draw")
        report["adjustedMaskDraw"] = adjusted.evidence(start: adjustedAt)
        return layer
    }

    static func maskDiagnostics(_ d: DevelopmentMaskAnalysisDiagnostics) -> [String: Any] {
        ["sourceContentID":d.sourceContentID, "decoder":d.decoder, "orientation":d.exifOrientation,
         "orientedWidth":d.orientedWidth, "orientedHeight":d.orientedHeight,
         "analysisWidth":d.analysisWidth, "analysisHeight":d.analysisHeight, "flashRawDecodes":d.flashRawDecodes,
         "coreImageRawDecodes":d.coreImageRawDecodes, "imageIODecodes":d.imageIODecodes, "hashChecks":d.sourceHashChecks,
         "exactHits":d.exactCacheHits, "successfulGenerations":d.successfulGenerations, "modelInvocations":d.modelInvocations,
         "visionRequests":d.visionRequests, "landscapeRuns":d.landscapeRuns,
         "objectEncoderRuns":d.objectEncoderRuns, "objectDecoderRuns":d.objectDecoderRuns]
    }

    @MainActor static func exportReopenedMask(library: URL, workID: String, layer: DevelopmentMaskLayerV3,
                                              output: URL, report: inout [String: Any]) async throws {
        let store = try LibraryStore(databaseURL: library)
        let work = try store.photoWork(id: workID)
        let recipe = try Self.required(work.liveRecipe)
        let persisted = try Self.required(recipe.adjustmentsV3?.masks.first(where: { $0.id == layer.id }))
        Self.gate(persisted == layer, "mask.reopenedSnapshotAndSettings", &report)
        let snapshot = try Self.required(persisted.semanticSnapshot)
        try snapshot.validate(png: Self.required(persisted.subjectPNG))
        let destination = output.appending(path: "reopened-subject.tiff")
        let started = DispatchTime.now().uptimeNanoseconds
        let renderer = ImageEngines.makeDevelopmentRenderer()
        let rendered = try await renderer.render(source: work.source, recipe: recipe, format: .tiff16,
                                                             destination: destination, protectedURLs:[work.source.sourceLocation], preparePublication:nil)
        report["reopenedRecipeExportMs"] = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        report["memoryAfterExport"] = try Self.maskProcessMemory()
        let reader = try Self.required(CGImageSourceCreateWithURL(rendered.fileURL as CFURL, nil))
        let frame = try Self.required(CGImageSourceCreateImageAtIndex(reader, 0, [kCGImageSourceShouldCache: false] as CFDictionary))
        report["export"] = ["file": destination.lastPathComponent, "width": frame.width, "height": frame.height,
                            "bitsPerComponent": frame.bitsPerComponent, "sha256": try FileSafety.hash(rendered.fileURL)] as [String: Any]
        Self.gate(frame.width == snapshot.source.orientedWidth && frame.height == snapshot.source.orientedHeight &&
            frame.bitsPerComponent == 16, "mask.fullSizeTIFF16", &report)

        var controlRecipe = recipe
        var parameters = try Self.required(recipe.adjustmentsV3)
        let index = try Self.required(parameters.masks.firstIndex(where: { $0.id == layer.id }))
        parameters.masks[index].enabled = false
        controlRecipe.adjustmentsV3 = parameters
        let control = try await renderer.render(source: work.source, recipe: controlRecipe, format: .tiff16,
            destination: output.appending(path: "disabled-layer-control.tiff"), protectedURLs:[work.source.sourceLocation], preparePublication:nil)
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
            var matched = try Self.required(recipe.adjustmentsV3)
            let emptyBitmap = try DevelopmentMaskBitmap(width: snapshot.width, height: snapshot.height,
                values: [UInt8](repeating: 0, count: snapshot.width * snapshot.height))
            let emptyPNG = try emptyBitmap.png()
            matched.masks[index].subjectPNG = emptyPNG
            matched.masks[index].semanticSnapshot = .init(source: snapshot.source, target: snapshot.target,
                generator: snapshot.generator, modelHashes: snapshot.modelHashes, prompt: snapshot.prompt,
                width: snapshot.width, height: snapshot.height, png: emptyPNG)
            matchedRecipe.adjustmentsV3 = matched
            let samePrefix = try await renderer.render(source: work.source, recipe: matchedRecipe, format: .tiff16,
                destination: output.appending(path: "same-renderer-zero-coverage.tiff"), protectedURLs:[work.source.sourceLocation], preparePublication:nil)
            report["zeroCoverageTIFFSHA256"] = try FileSafety.hash(samePrefix.fileURL)
            difference = try await Task.detached {
                try compareMaskExports(edited: rendered.fileURL, control: samePrefix.fileURL, layer: persisted)
            }.value
        }
        report["pixelComparison"] = difference
        Self.gate((difference["protectedPixels"] ?? 0) > 0 && difference["protectedMaximumRGBA16Difference"] == 0,
            "mask.samePrefixProtectedPixelsExact", &report)
        Self.gate((difference["selectedPixels"] ?? 0) > 0 && (difference["selectedBrighterPixels"] ?? 0) > 0 &&
            (difference["selectedRGBSumGain"] ?? 0) > 0, "mask.nonemptySelectionBrighter", &report)
    }

    // The fresh work has identity geometry. A subject layer reads only its frozen Gray8 and opacity.
    private static func compareMaskExports(edited: URL, control: URL, layer: DevelopmentMaskLayerV3) throws -> [String: Int] {
        let options: [CIImageOption: Any] = [.colorSpace: NSNull(), .applyOrientationProperty: true]
        let adjusted = try Self.required(CIImage(contentsOf: edited, options: options))
        let reference = try Self.required(CIImage(contentsOf: control, options: options))
        guard adjusted.extent == reference.extent, layer.kind == .subject else { throw EditingError.invalidRecipe }
        let bounds = adjusted.extent
        let width = Int(bounds.width), height = Int(bounds.height)
        let selection = DevelopmentMaskEngineV3.ScopeSelection(layer)
        try selection.capture(CIImage(color: .white).cropped(to: bounds))
        let coverage = try Self.required(selection.coverage)
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
