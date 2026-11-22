import AppKit
import CryptoKit
import Metal
import SwiftUI
import XCTest
@testable import RAWMaster
import RAWMasterCore
@testable import RAWMasterImaging

/// Measures the products of an actual analysis, pointer readout or scope raster. The photo is opened once.
@MainActor final class PhotoInspectionPerformanceTests: XCTestCase {
    private struct Witness {
        var numbers: [Double] = []
        var text: String = ""
        var raster = Data()
        var diagnostics: [String: [Double]] = [:]

        func digest() throws -> String {
            guard numbers.allSatisfy(\.isFinite), !numbers.isEmpty || !text.isEmpty || !raster.isEmpty else {
                throw Failure("Empty or non-finite output")
            }
            var bytes = try JSONEncoder().encode(numbers.map { ($0 * 1e6).rounded() / 1e6 })
            bytes.append(contentsOf: text.utf8)
            bytes.append(raster)
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Select only pixels on the actual dashed skin ray which visibly brighten in the guide-on raster.
    /// The two orientations account for the top-left view and the bottom-left bitmap coordinate systems.
    private struct SkinGuidePixels {
        struct Pixel { let x, y: Int; let off, on: Double }
        let selected: [Pixel]
        let orientation: Int
        let width = 256, height = 168

        static func luma(_ data: Data, x: Int, y: Int) -> Double {
            let i = 4 * (256 * y + x)
            return Double(data[i]) * 0.2126 + Double(data[i+1]) * 0.7152 + Double(data[i+2]) * 0.0722
        }

        init(off: Data, on: Data) throws {
            guard off.count == width * height * 4, on.count == off.count else { throw Failure("Scope geometry mismatch") }
            let angle = PhotosVectorscopeOrientation.angle(hue: PhotosVectorscope.skinHue, redAtThree: false)
            let radius = Double(min(width, height)) / 2 - 9
            func candidates(sign: Int) -> [Pixel] {
                var result: [Pixel] = []
                let dx = cos(angle), dy = Double(sign) * sin(angle)
                for y in 0..<168 { for x in 0..<256 {
                    let px = Double(x) + 0.5 - 128, py = Double(y) + 0.5 - 84
                    let t = px * dx + py * dy, normal = abs(px * dy - py * dx)
                    guard t > radius * 0.15, t < radius * 0.92, normal < 1.35 else { continue }
                    let a = Self.luma(off, x: x, y: y), b = Self.luma(on, x: x, y: y)
                    if b - a >= 24 { result.append(.init(x: x,y: y,off: a,on: b)) }
                } }
                return result
            }
            let up = candidates(sign: -1), down = candidates(sign: 1)
            selected = up.count > down.count ? up : down
            orientation = up.count > down.count ? -1 : 1
            guard selected.count >= 12, selected.count >= 3 * max(1, min(up.count, down.count)) else {
                throw Failure("Skin guide lacks a localized visible calibration along its expected ray")
            }
        }

        func read(_ image: Data, wanted: Int) throws -> Witness {
            let values = selected.map { Self.luma(image, x: $0.x, y: $0.y) }
            let onCount = zip(selected, values).filter { $1 >= ($0.off + $0.on) / 2 }.count
            let fraction = Double(onCount) / Double(selected.count)
            guard wanted == 0 ? fraction <= 0.1 : fraction >= 0.9 else { throw Failure("Skin reference pixels disagree with the toggle state") }
            return Witness(numbers: [fraction >= 0.9 ? 1 : 0], diagnostics: ["fractionAboveGuideMidpoint": [fraction], "guidePixelLumaRGB8": values])
        }
    }

    private struct ChromaPixels {
        struct Pixel { let x, y: Int; let a, b: [Int] }
        let pixels: [Pixel]
        static func rgb(_ image: Data, _ x: Int, _ y: Int) -> [Int] {
            let i = (y * 256 + x) * 4
            return [Int(image[i]), Int(image[i+1]), Int(image[i+2])]
        }
        static func distance(_ a: [Int], _ b: [Int]) -> Int {
            abs(a[0]-b[0]) + abs(a[1]-b[1]) + abs(a[2]-b[2])
        }
        init(_ a: Data, _ b: Data) throws {
            guard a.count == 256*168*4, b.count == a.count else { throw Failure("Scope raster geometry mismatch") }
            var candidates: [Pixel] = []
            for y in stride(from: 16,to: 152,by: 2) { for x in stride(from: 60,to: 196,by: 2) {
                let radius = hypot(Double(x-128), Double(y-84))
                guard (8...67).contains(radius) else { continue }
                let p = Self.rgb(a,x,y), q = Self.rgb(b,x,y)
                if Self.distance(p,q) >= 90 { candidates.append(.init(x:x,y:y,a:p,b:q)) }
            } }
            guard candidates.count >= 24 else { throw Failure("The original chroma traces lack sufficient distinct plot pixels") }
            let count = min(candidates.count, 96)
            pixels = (0..<count).map { candidates[$0 * candidates.count/count] }
        }
        func read(_ image: Data, wanted: Int) throws -> Witness {
            let observed = pixels.map { Self.rgb(image,$0.x,$0.y) }
            let towardsB = zip(pixels,observed).filter { Self.distance($1,$0.b) < Self.distance($1,$0.a) }.count
            let fraction = Double(towardsB)/Double(pixels.count)
            guard wanted == 0 ? fraction <= 0.1 : fraction >= 0.9 else { throw Failure("Chroma plot pixels did not reproduce the target distribution") }
            return Witness(numbers:[fraction >= 0.9 ? 1 : 0],diagnostics:["fractionClosestToB":[fraction],"plotRGB8":observed.flatMap { $0.map(Double.init) }])
        }
    }

    private struct Failure: LocalizedError {
        var message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    private func draw(_ view: PhotosVectorscope) throws -> Witness {
        let width = 256, height = 168
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height))
            .environment(\.colorScheme, .dark))
        renderer.scale = 1
        guard let image = renderer.cgImage else { throw Failure("Scope raster missing") }
        var bytes = Data(count: width * height * 4)
        let ok = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { throw Failure("Scope bitmap failed to materialize") }
        return Witness(raster: bytes)
    }

    func testRealRAWAnalysisAndInspection() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let input = env["RAWMASTER_INSPECTION_RAW"], let output = env["RAWMASTER_INSPECTION_REPORT"] else {
            throw XCTSkip("Set RAWMASTER_INSPECTION_RAW and RAWMASTER_INSPECTION_REPORT")
        }
        #if DEBUG
        throw XCTSkip("Use a Release build")
        #endif
        guard !FileManager.default.fileExists(atPath: output) else { throw CocoaError(.fileWriteFileExists) }
        let sourceURL = URL(fileURLWithPath: input), destination = URL(fileURLWithPath: output)
        let hash = try RenderFiles.hash(sourceURL)
        let bytes = try XCTUnwrap(sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        let source = EditingSourceSnapshot(projectID: "inspection-benchmark", assetID: "original",
            contentSHA256: hash, byteCount: Int64(bytes), admissionFingerprint: "inspection-v1", sourceLocation: sourceURL)
        let decoder = try XCTUnwrap(DevelopmentRAWSourcePolicy.decoderForNewWork(at: sourceURL))
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 1_073_741_824,
                                                              interactiveEvaluation: .proxyV1))
        let session = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
        do {
            let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
            var payload = DevelopmentAdjustmentsV3()
            payload.rawDecoder = decoder
            let neutral = DevelopmentRecipe(adjustmentsV3: payload)
            var revision = UInt64(0)
            func request(_ recipe: DevelopmentRecipe, quality: PreviewQuality = .settled) -> DevelopmentPreviewRequest {
                revision += 1
                return .init(sessionID: session.id, sourceGeneration: session.sourceGeneration, consumerID: consumer,
                    role: .primary, revision: revision, recipe: recipe, quality: quality, viewport: .init(maxPixel: 2400))
            }
            func analyze(_ recipe: DevelopmentRecipe, _ operation: DevelopmentAnalysisOperation,
                         _ stage: DevelopmentAnalysisStage = .workingImageBeforeGeometry) async throws -> DevelopmentAnalysisResult {
                let input = DevelopmentAnalysisRequest(preview: request(recipe), expectedRecipeFingerprint: try EditingFingerprint.of(recipe),
                                                       stage: stage, operation: operation)
                let answer = try await service.analyze(input)
                guard answer.operationID == input.operationID, answer.actualRecipe == recipe,
                      answer.sourceBinding == facts.sourceBinding else { throw Failure("Mismatched source or analysis response") }
                return answer
            }
            let rawFrame = try await service.render(request(neutral, quality: .interactive))
            let frame = EditingPreviewBitmap(rawFrame)
            guard frame.outputSize == CGSize(width: 2400, height: 1600) else { throw Failure("Unexpected RAW witness dimensions") }
            let positions = [DevelopmentSourcePoint(x: 0.29, y: 0.31), .init(x: 0.73, y: 0.69)]
            let passes = Int(env["RAWMASTER_INSPECTION_SAMPLES"] ?? "10") ?? 10
            guard (2...100).contains(passes) else { throw Failure("Incorrect sample count") }
            let testBinary = try XCTUnwrap(Bundle(for: Self.self).executableURL)
            var report: [String: Any] = [
                "schemaVersion": 1, "application": "RAWMaster", "protocol": "rawmaster-analysis-and-inspection-v1",
                "build": "release", "binarySHA256": try RenderFiles.hash(testBinary),
                "recordedAt": ISO8601DateFormatter().string(from: Date()), "sourceSHA256": hash,
                "sourcePixels": [facts.sourceBinding.orientedWidth, facts.sourceBinding.orientedHeight],
                "inspectionFramePixels": [2400,1600], "scopeRasterPixels": [256,168], "decoder": decoder.rawValue,
                "os": ProcessInfo.processInfo.operatingSystemVersionString, "gpu": MTLCreateSystemDefaultDevice()?.name ?? "unknown",
                "repeats": passes, "positionA": [positions[0].x, positions[0].y], "positionB": [positions[1].x, positions[1].y],
                "clock": "DispatchTime.uptimeNanoseconds; result verification/hash and JSON outside timed interval"
            ]
            var rows: [[String: Any]] = []
            var supplementary: [[String: Any]] = []
            let selected = Set((env["RAWMASTER_INSPECTION_ONLY"] ?? "").split(separator: ",").map(String.init))
            func write() throws {
                report["operations"] = rows
                report["supplementaryOperations"] = supplementary
                let bytes = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                try bytes.write(to: destination, options: .atomic)
            }
            func measure(_ id: String, _ boundary: String, _ input: String, distinct: Bool = true, prepare: ((Int) throws -> Void)? = nil,
                         body: (Int) async throws -> Witness) async throws {
                guard selected.isEmpty || selected.contains(id) else { return }
                var row: [String: Any] = ["id": id, "boundary": boundary, "input": input,
                    "status": "inconclusive", "verification": distinct ? "two stable different result digests" : "each automatic result changes the input; repeatable per state"]
                var samples: [[String: Any]] = []
                var seen = [Set<String>(), Set<String>()]
                do {
                    for index in 0..<passes + 2 {
                        let state = index % 2
                        try prepare?(state)
                        let start = DispatchTime.now().uptimeNanoseconds
                        let result = try await body(state)
                        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                        let digest = try result.digest()
                        seen[state].insert(digest)
                        var sample: [String: Any] = ["state": state, "phase": index < 2 ? "first" : "warm", "ms": elapsed, "digest": digest]
                        if !result.numbers.isEmpty { sample["values"] = result.numbers }
                        if !result.text.isEmpty { sample["text"] = result.text }
                        if !result.diagnostics.isEmpty { sample["witness"] = result.diagnostics }
                        samples.append(sample)
                    }
                    guard seen.allSatisfy({ $0.count == 1 }), !distinct || seen[0] != seen[1] else {
                        throw Failure("Output did not repeat within each state or distinguish the two requested states")
                    }
                    row["status"] = "measured"
                } catch { row["reason"] = error.localizedDescription }
                row["samples"] = samples
                if id == "global-auto-light-and-color" { supplementary.append(row) } else { rows.append(row) }
                try write()
                print("INSPECTION \(id) \(row["status"]!) \(row["reason"] ?? "")")
            }
            func photoPixels(_ recipe: DevelopmentRecipe) async throws -> Data {
                let rendered = try await service.render(request(recipe, quality:.interactive))
                guard rendered.outputPixelSize == frame.outputSize else { throw Failure("Unexpected photo size") }
                let bytes = UnsafeMutableRawBufferPointer.allocate(byteCount:2400*1600*4, alignment:64)
                defer { bytes.deallocate() }
                try rendered.copyDisplayRGBA8(into: bytes)
                var sample = Data(capacity:96*64*3)
                for y in 0..<64 { for x in 0..<96 {
                    let index = 4*((2*y+1)*1600/128*2400 + (2*x+1)*2400/192)
                    guard bytes[index+3] == 255 else { throw Failure("Transparent RAW sample") }
                    sample.append(contentsOf: bytes[index..<(index+3)])
                }}
                return sample
            }
            let focusControls = ["blur-point-focus","blur-area-focus","blur-subject-focus"]
            if selected.isEmpty || !selected.isDisjoint(with:focusControls) {
                let scene = try await ImageEngines.sceneDepth.estimate(source)
                guard scene.sourceSHA256 == hash else { throw Failure("Focus map belongs to another photo") }
                let mapping = try payload.geometry.mapping(sourceSize:facts.sourceBinding.sourceSize)
                for id in focusControls {
                    let subject = id == "blur-subject-focus"
                    try await measure(id, "source-bound focus selection through 2400px rendered lens blur and sampled RGB",
                                      subject ? "repeat Vision subject selection from two displaced focus points" :
                                        "alternate two points or two rectangles on the real inferred depth map", distinct:!subject) { state in
                        var blur = DevelopmentLensBlurV3(enabled:true,amount:0.85,focusX:positions[state].x,
                            focusY:positions[state].y,focusRange:0.07)
                        blur.sceneDepth = scene
                        let point = try mapping.sourcePoint(fromOutput:positions[state])
                        switch id {
                        case "blur-subject-focus":
                            let answer = try await DevelopmentSubjectAnalysis.shared.focus(for:source)
                            guard answer.weightedPixelCount > 1, (0...1).contains(answer.focusRange),
                                  answer.focusX != blur.focusX || answer.focusY != blur.focusY else { throw Failure("No recognised subject") }
                            blur.focusRange = answer.focusRange
                            try blur.focus(at:.init(x:answer.focusX,y:answer.focusY))
                        case "blur-area-focus":
                            let corner = try mapping.sourcePoint(fromOutput:.init(x:positions[state].x + 0.12, y:positions[state].y + 0.1))
                            try blur.focus(from:point,to:corner,sourceSize:facts.sourceBinding.sourceSize)
                        default: try blur.focus(at:point)
                        }
                        var changed = payload; changed.effects = .init(lensBlur:blur)
                        let rgb = try await photoPixels(.init(adjustmentsV3:changed))
                        return Witness(numbers:[blur.focusX,blur.focusY,blur.focusRange],raster:rgb,
                            diagnostics:["sampleRGB8SHA256":SHA256.hash(data:rgb).map(Double.init)])
                    }
                }
            }
            if selected.isEmpty || selected.contains("grading-lut-import") {
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
                defer { try? FileManager.default.removeItem(at:folder) }
                let cubes = try PhotoInspectionFixtures.writeCubes(in:folder)
                try await measure("grading-lut-import","real RAW open · import CUBE to new on-disk library, load the persisted LUT and return its rendered photo",
                                  "alternate warm and monochrome 17³ CUBE files with a new library per trial") { state in
                    let lib = DevelopmentLUTLibrary(directory:folder.appendingPathComponent(UUID().uuidString))
                    let entries = try await lib.importFile(cubes[state])
                    guard entries.count == 1 else { throw Failure("Unexpected number of imported LUTs") }
                    let cube = try await lib.load(entries[0])
                    guard cube.dimension == 17 else { throw Failure("Unexpected LUT size") }
                    var changed = payload
                    changed.gradingLUTs = .init(layers:[.init(id:UUID(uuidString:"3C2456C2-EE20-42FD-A4E3-9B0D271A6003")!,cube:cube)])
                    let rgb = try await photoPixels(.init(adjustmentsV3:changed))
                    return Witness(text:cube.id,raster:rgb,diagnostics:["sampleRGB8SHA256":SHA256.hash(data:rgb).map(Double.init)])
                }
            }
            let analysisBoundary = "raw.analysis · service submission through source-bound resolved recipe and numeric value"
            try await measure("light-clipping-modifier", "histogram modifier and zone to returned 2400px temporary preview and 96×64 RGB observation",
                              "hold/release Option in highlights zone over fixed +1.1 exposure parameter") { state in
                var transient = payload
                transient.light = .init(enabled:true,exposure:1.1)
                let flags: NSEvent.ModifierFlags = state == 0 ? [] : [.option]
                transient.light.clippingPreview = PhotosHistogramZone.at(0.8).clippingMode(for: flags)
                let output = try await service.render(request(.init(adjustmentsV3:transient), quality:.interactive))
                guard let cg = output.image.cgImage(forProposedRect:nil,context:nil,hints:nil) else { throw Failure("No clipping frame") }
                let w = 96, h = 64
                var rgb = Data(count:w*h*4)
                try rgb.withUnsafeMutableBytes { buffer in
                    guard let context = CGContext(data:buffer.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w*4,
                        space:CGColorSpace(name:CGColorSpace.sRGB)!, bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
                    else { throw Failure("Could not read clipping preview") }
                    context.interpolationQuality = .none; context.draw(cg,in:.init(x:0,y:0,width:w,height:h))
                }
                return Witness(raster:rgb)
            }
            let pointID = UUID(uuidString: "07753528-3E35-49EB-B57E-00FCCF13143B")!
            let analysisIDs = ["light-auto", "light-auto-single", "global-auto-light-and-color", "color-wb-auto", "color-wb-picker",
                               "mixer-point-picker", "optics-defringe-picker", "mixer-tat", "curve-tat-point"]
            for id in analysisIDs {
                let automatic = ["light-auto","light-auto-single","global-auto-light-and-color","color-wb-auto"].contains(id)
                let label = automatic ? "full source Auto; two starting recipes" : "alternating source-top-left coordinates A/B"
                let boundary = ["mixer-tat", "curve-tat-point"].contains(id)
                    ? "raw.analysis · sample through first nonzero targeted drag and validated parameters" : analysisBoundary
                try await measure(id, boundary, label, distinct: !automatic) { state in
                    let p = positions[state]
                    var before = payload
                    var stage = DevelopmentAnalysisStage.workingImageBeforeGeometry
                    let operation: DevelopmentAnalysisOperation
                    switch id {
                    case "light-auto", "light-auto-single", "global-auto-light-and-color":
                        before.light.enabled = true; before.light.exposure = state == 0 ? -0.6 : -0.3
                        operation = id == "light-auto-single" ? .automaticLight(.exposure) : .automatic(id == "light-auto" ? .light : nil)
                    case "color-wb-auto", "color-wb-picker":
                        stage = .orientedSourceBeforeGeometry
                        guard case let .raw(binding, initial) = try DevelopmentWhiteBalanceEngineV3.initialState(
                            source: facts.sourceBinding, rawDefault: facts.asShotWhiteBalance) else { throw Failure("Expected native RAW white balance") }
                        var wb = initial; wb.selectedMode = .temperatureTint
                        wb.temperatureTint = .init(temperature: state == 0 ? 2650 : 3590, tint: 4)
                        before.whiteBalance = .init(enabled: true, resolvedState: .raw(source: binding, state: wb))
                        operation = id == "color-wb-auto" ? .whiteBalanceAutomatic(mode: .temperatureTint)
                            : .whiteBalancePicker(sourcePoint: p, mode: .neutralGray(warmth: 0))
                    case "mixer-point-picker": operation = .pointColorPicker(id: pointID, sourcePoint: p)
                    case "optics-defringe-picker": operation = .defringePicker(band: .purple, sourcePoint: p)
                    case "mixer-tat": operation = .selectiveColorPicker(slot: .blue, sourcePoint: p)
                    default: operation = .curvePicker(channel: .rgb, point: .addPoint, sourcePoint: p)
                    }
                    let recipe = DevelopmentRecipe(adjustmentsV3: before)
                    let result = try await analyze(recipe, operation, stage)
                    guard case .resolved(let command) = result.value else { throw Failure("No resolved adjustment") }
                    let next = try recipe.applying(.applyAnalysis(command), context: .init(source: facts.sourceBinding,
                        sourceGeneration: session.sourceGeneration, analysisStage: stage, sourceCapability: .raw))
                    guard let changed = next.adjustmentsV3, changed != before else { throw Failure("No change from initial adjustment") }
                    switch id {
                    case "light-auto", "light-auto-single", "global-auto-light-and-color":
                        let tone = changed.light
                        if id == "light-auto-single" {
                            var expected = before.light; expected.exposure = tone.exposure
                            guard expected == tone, tone.exposure != before.light.exposure else { throw Failure("Single-field projection failed") }
                        }
                        var values = [tone.exposure,tone.contrast,tone.highlights,tone.shadows,tone.whites,tone.blackPoint]
                        if id == "global-auto-light-and-color" {
                            guard command.parameters.map(\.id) == [.light,.color], changed.color != before.color else { throw Failure("Expected global color and light") }
                            values.append(contentsOf: [changed.color.vibrance,changed.color.saturation])
                        }
                        return Witness(numbers: values)
                    case "color-wb-auto", "color-wb-picker":
                        guard case let .raw(_, wb) = changed.whiteBalance.resolvedState, let target = try wb.nativeTarget(),
                              wb.selectedMode == (id == "color-wb-auto" ? .temperatureTint : .neutralGray) else { throw Failure("No native WB target") }
                        return Witness(numbers: [Double(target.temperature), Double(target.tint)])
                    case "mixer-point-picker":
                        guard let c = changed.selectiveColor.pointColors?.first(where: { $0.id == pointID })?.sampledColor else { throw Failure("No source swatch") }
                        return Witness(numbers: [c.red,c.green,c.blue])
                    case "optics-defringe-picker":
                        guard let band = changed.optics?.defringe, band.enabled, band.purpleAmount > 0 else { throw Failure("No defringe range") }
                        return Witness(numbers: [band.purpleHueLower,band.purpleHueUpper,band.purpleAmount])
                    case "mixer-tat":
                        guard let c = changed.selectiveColor.colors.first(where: { $0.slot == .blue })?.sampledColor else { throw Failure("No targeted color") }
                        let adjusted = try DevelopmentTargetedColorAdjustmentV3.apply(initial: changed.selectiveColor, sample: c, mode: .saturation, drag: 0.3)
                        guard adjusted != changed.selectiveColor else { throw Failure("No HSL drag result") }
                        return Witness(numbers: adjusted.colors.map(\.saturation))
                    default:
                        let points = changed.curves.rgb.curve.points
                        guard let index = points.firstIndex(where: { !before.curves.rgb.curve.points.contains($0) }) else { throw Failure("No sampled curve point") }
                        let adjusted = try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial: changed.curves, channel: .rgb,
                            pointIndex: index, translation: .init(x: 0, y: 0.13))
                        guard adjusted != changed.curves else { throw Failure("No curve drag result") }
                        return Witness(numbers: adjusted.rgb.curve.points.flatMap { [$0.x,$0.y] })
                    }
                }
            }

            if selected.isEmpty || selected.contains("mixer-point-swatches") {
                var seven = payload
                let seed = (1...8).map { UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", $0))! }
                func append(_ index: Int, position: DevelopmentSourcePoint) async throws -> DevelopmentSelectiveColorV3 {
                    let recipe = DevelopmentRecipe(adjustmentsV3: seven)
                    let result = try await analyze(recipe, .pointColorPicker(id: seed[index], sourcePoint: position))
                    guard case .resolved(let value) = result.value,
                          case .selectiveColor(let color) = value.parameters.first else { throw Failure("No swatch result") }
                    return color
                }
                for i in 0..<7 {
                    seven.selectiveColor = try await append(i, position: .init(x: Double(i + 1) / 9, y: i.isMultiple(of: 2) ? 0.38 : 0.64))
                }
                try await measure("mixer-point-swatches", "raw.analysis · add the eighth measured swatch while preserving the previous seven real RAW samples",
                                  "seven existing sampled swatches kept constant, eighth picked at A/B") { state in
                    let updated = try await append(7, position: positions[state])
                    guard let all = updated.pointColors, all.count == 8, all.last?.id == seed[7],
                          Array(all.dropLast()) == seven.selectiveColor.pointColors else { throw Failure("Swatch list or original samples changed") }
                    let c = all[7].sampledColor
                    return Witness(numbers: [Double(all.count),c.red,c.green,c.blue])
                }
            }

            let view = ImageCanvasViewportSnapshot(frameID: frame.id, viewportSize: frame.outputSize,
                imagePixelSize: frame.outputSize, imageRect: .init(origin: .zero, size: frame.outputSize), backingScale: 1, transform: .init())
            for id in ["color-rgb-readout", "color-lab-readouts"] {
                let readout = PhotosColorReadout(), lab = id == "color-lab-readouts"
                try await measure(id, "resident preview · canvas hover event to formatted inspector text", "alternate pointer positions A/B") { state in
                    let p = positions[state]
                    readout.update(.init(viewport: view, locationInView: .init(x: p.x * frame.outputSize.width,
                        y: p.y * frame.outputSize.height), modifiersRawValue: 0), frame: frame)
                    guard let sample = readout.pixel, let text = readout.formatted(showLab: lab) else { throw Failure("Missing pointer sample") }
                    let c = lab ? sample.lab : sample.rgb
                    return Witness(numbers: [c.x,c.y,c.z], text: text)
                }
            }
            let suite = "rawmaster.inspection." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            if selected.isEmpty || selected.contains("color-floating-scopes") {
                defaults.set(true,forKey:"editing.scope.vectorscope")
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                defer { try? FileManager.default.removeItem(at:directory) }
                let database = directory.appendingPathComponent("inspection.sqlite")
                let asset = try NativePresentedCanvasTests.register(source:sourceURL,library:database)
                let model = AppModel(libraryURL:database,defaults:defaults)
                let editor = try XCTUnwrap(model.editing)
                editor.isPresented = true
                editor.focus(asset)
                let deadline = ContinuousClock.now + .seconds(35)
                while editor.developmentHistogram == nil && ContinuousClock.now < deadline {
                    if editor.work != nil && editor.developmentContext == nil { editor.beginDevelopmentInterface() }
                    try await Task.sleep(for:.milliseconds(20))
                }
                try await measure("color-floating-scopes","detached scope · create and size a hidden native panel through first raster of the real photo vectorscope",
                                  "same photo histogram, render floating content at 360×280 / 480×360 points") { state in
                    let size = state == 0 ? CGSize(width:360,height:280) : .init(width:480,height:360)
                    let observation = try PhotoInspectionFixtures.detachedScope(editing:editor, defaults:defaults, size:size)
                    return Witness(numbers:[observation[0],observation[1],observation[3]], diagnostics:["chromaticPlotPixels":[observation[2]]])
                }
                await editor.shutdown()
            }
            let workflow = PhotoWorkflowBenchmark(facts: facts, raw: hash, generation: session.sourceGeneration, baseline: payload, defaults: defaults)
            for item in PhotoWorkflowBenchmark.cases {
                try await measure(item.id, item.boundary, item.input, distinct: item.distinct, prepare: { try workflow.prepare(item.id, state: $0) }) { state in
                    let reading = try workflow.perform(item.id, state: state)
                    return Witness(numbers: reading.values, text: reading.text)
                }
            }
            let samplers = PhotosColorSamplers(defaults: defaults)
            samplers.bind(workID: "inspection", sourceID: hash)
            for n in 1...9 { guard samplers.place(.init(x: Double(n)/10, y: 0.5)) else { throw Failure("Missing annotation slot") } }
            let mapping = try payload.geometry.mapping(sourceSize: facts.sourceBinding.sourceSize)
            try await measure("color-samplers", "resident preview · place/replace persisted source annotation and recalculate nine displayed samples",
                              "replace annotation 1 at A/B; eight fixed existing annotations") { state in
                let point = try mapping.sourcePoint(fromOutput: positions[state])
                guard DevelopmentDisplayPixel.sample(frame.image, at: positions[state]) != nil, samplers.place(point, replacing: 0)
                else { throw Failure("Photo annotation rejected") }
                let colors = samplers.colors(frame: frame, mapping: mapping).compactMap { $0 }
                guard colors.count == 9, samplers.points[0] == point else { throw Failure("Missing sampler row") }
                return Witness(numbers: colors.flatMap { [$0.rgb.x,$0.rgb.y,$0.rgb.z] })
            }
            try await measure("curve-tat-parametric", "resident preview · oriented pixel pick, tonal-region selection, first nonzero drag and validated parameters",
                              "select pixel A/B; apply +0.1 / -0.15 vertical drag") { state in
                guard let pixel = DevelopmentDisplayPixel.sample(frame.image, at: positions[state]) else { throw Failure("No curve source pixel") }
                let region = try DevelopmentTargetedCurveAdjustmentV3.region(tone: pixel.tone, curve: .init())
                let adjusted = try DevelopmentTargetedCurveAdjustmentV3.applyParametric(initial: payload.curves, region: region,
                    translation: .init(0, state == 0 ? 0.1 : -0.15))
                guard let c = adjusted.parametric, c != .init() else { throw Failure("No parametric change") }
                return Witness(numbers: [pixel.tone,c.shadows,c.darks,c.lights,c.highlights])
            }
            if selected.isEmpty || !selected.isDisjoint(with: ["color-vectorscope","color-skin-indicator"]) {
                var distributions: [DevelopmentDisplayHistogramV1] = []
                for amount in [0.0,0.69] {
                    var variant = payload; variant.color = .init(enabled: true, saturation: amount)
                    let result = try await analyze(DevelopmentRecipe(adjustmentsV3: variant), .displayHistogram)
                    guard case let .displayHistogram(data) = result.value,
                          data.chroma.reduce(0, { $0 + Int($1) }) == data.visibleSamples, data.visibleSamples > 0
                    else { throw Failure("No real RAW chroma distribution") }
                    distributions.append(data)
                }
                guard distributions[0].chroma != distributions[1].chroma else { throw Failure("Indistinguishable scope input bins") }
                report["scopeInputs"] = distributions.map { ["visibleSamples":$0.visibleSamples, "sampledWidth":$0.sampledSize.width,
                    "sampledHeight":$0.sampledSize.height,"occupiedChromaBins":$0.chroma.filter { $0 > 0 }.count] }
                if selected.isEmpty || selected.contains("color-vectorscope") {
                    let calibration = try distributions.map { try draw(PhotosVectorscope(histogram:$0,skinIndicator:false,redAtThree:false)).raster }
                    let trace = try ChromaPixels(calibration[0],calibration[1])
                    report["chromaCalibration"] = ["minimumRGB8ChannelSumDifference": 90, "minimumAgreement": 0.9,
                        "referencePixelsXYRGBaRGBb": trace.pixels.map { [$0.x, $0.y] + $0.a + $0.b }] as [String:Any]
                    try await measure("color-vectorscope", "prepared real RAW chroma distribution to original SwiftUI scope raster and chroma plot pixel readout",
                                      "same source under saturation 0 / +0.69; calibrated pixels inside the chroma plot; no skin guide") { state in
                        let image = try draw(PhotosVectorscope(histogram: distributions[state], skinIndicator: false, redAtThree: false))
                        return try trace.read(image.raster, wanted: state)
                    }
                }
                if selected.isEmpty || selected.contains("color-skin-indicator") {
                    let reference = try [false, true].map {
                        try draw(PhotosVectorscope(histogram: distributions[0], skinIndicator: $0, redAtThree: false)).raster
                    }
                    let guide = try SkinGuidePixels(off: reference[0], on: reference[1])
                    report["skinGuideCalibration"] = ["width": guide.width, "height": guide.height, "verticalSign": guide.orientation,
                        "minimumRGB8Brightening": 24, "minimumAgreement": 0.9,
                        "referencePixelsXYOffOnLuma": guide.selected.map { [Double($0.x),Double($0.y),$0.off,$0.on] }] as [String: Any]
                    try await measure("color-skin-indicator", "prepared real RAW chroma distribution to original SwiftUI scope raster and skin-ray readout",
                                      "toggle the reference over identical RAW bins; compare observed pixels only on its calibrated dashed ray") { state in
                        let image = try draw(PhotosVectorscope(histogram: distributions[0], skinIndicator: state == 1, redAtThree: false))
                        return try guide.read(image.raster, wanted: state)
                    }
                }
            }
            guard selected.isSubset(of: Set((rows + supplementary).compactMap { $0["id"] as? String })) else { throw Failure("Unknown selected operation") }
            let cache = await service.analysisStatistics()
            report["analysisCache"] = ["workingImageHits":cache.workingImageHits,"workingImageBuilds":cache.workingImageBuilds,
                "scalarHistoryHits":cache.scalarHistoryHits,"scalarHistoryEntries":cache.scalarHistoryEntries,"retainedRawTextureBytes":cache.retainedWorkingSourceBytes] as [String:Any]
            report["sourceSHA256After"] = try RenderFiles.hash(sourceURL)
            guard report["sourceSHA256After"] as? String == hash else { throw Failure("RAW source changed") }
            try write()
            await service.close(session.id)
        } catch { await service.close(session.id); throw error }
    }
}
