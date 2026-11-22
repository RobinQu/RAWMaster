import AppKit
import CryptoKit
import Metal
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Alternates the actual parameter on a resident real RAW. Readback is outside the timed call.
final class IndividualControlPerformanceTests: XCTestCase {
    struct Control {
        let id: String
        let states: [DevelopmentRecipe]
    }

    func controls(decoder: DevelopmentRAWDecoder?, facts: DevelopmentSourceFacts) throws -> [Control] {
        typealias Payload = DevelopmentAdjustmentsV3
        var cases: [Control] = []
        func add(_ id: String, _ mutate: (inout Payload, Bool) -> Void) {
            let states = [false, true].map { edited in
                var p = Payload()
                p.rawDecoder = decoder
                mutate(&p, edited)
                return DevelopmentRecipe(adjustmentsV3: p)
            }
            cases.append(Control(id: id, states: states))
        }
        let tones: [(String, WritableKeyPath<DevelopmentLightV3, Double>)] = [
            ("exposure", \.exposure), ("contrast", \.contrast), ("highlights", \.highlights),
            ("shadows", \.shadows), ("whites", \.whites), ("blacks", \.blackPoint)]
        for (id, field) in tones {
            add("light-" + id) { p, b in
                p.light.enabled = true
                p.light[keyPath: field] = b ? (id == "exposure" ? 0.25 : 0.3) : 0
            }
        }
        add("light-clipping-indicators") { $0.light.clippingPreview = $1 ? .highlights : .shadows }
        add("color-saturation") { $0.color = .init(enabled: true, saturation: $1 ? 0.3 : 0) }
        add("color-vibrance") { $0.color = .init(enabled: true, vibrance: $1 ? 0.3 : 0) }
        add("color-bw-treatment") { $0.blackAndWhite.enabled = $1 }
        if case let .raw(binding, initial) = try DevelopmentWhiteBalanceEngineV3.initialState(
            source: facts.sourceBinding, rawDefault: facts.asShotWhiteBalance) {
            for id in ["color-wb-as-shot", "color-wb-presets"] {
                add(id) { p, edited in
                    var state = initial
                    state.selectedMode = id == "color-wb-as-shot" && edited ? .asShot : .temperatureTint
                    state.temperatureTint = .init(temperature: edited ? 5500 : 2850, tint: edited ? 10 : 0)
                    p.whiteBalance = .init(enabled: true, resolvedState: .raw(source: binding, state: state))
                }
            }
            for field in ["color-temp-raw", "color-tint"] {
                add(field) { p, b in
                    var state = initial
                    state.selectedMode = .temperatureTint
                    state.temperatureTint = .init(temperature: field == "color-temp-raw" && b ? 6500 : 5500,
                                                   tint: field == "color-tint" && b ? 40 : 16)
                    p.whiteBalance = .init(enabled: true, resolvedState: .raw(source: binding, state: state))
                }
            }
        }

        for (id, field) in [("effects-texture", \DevelopmentAdvancedDetailV3.texture),
                            ("effects-clarity", \.clarity)] {
            add(id) { $0.advancedDetail[keyPath: field] = .init(enabled: true, amount: $1 ? 30 : 0) }
        }
        let glowFields: [(String, WritableKeyPath<DevelopmentGlowV3, Double>, Double, Double)] = [
            ("amount", \.amount, 0, 65), ("range", \.range, 40, 80), ("spread", \.spread, 30, 75),
            ("warmth", \.warmth, 0, 60), ("direction", \.direction, 0, 70), ("softness", \.softness, 20, 80)]
        for (id, field, low, high) in glowFields {
            add("effects-glow-" + id) { p, b in
                var glow = DevelopmentGlowV3(enabled: true, amount: 65, style: ["direction", "softness"].contains(id) ? .motion : .bloom)
                glow[keyPath: field] = b ? high : low
                p.effects = .init(glow: glow)
            }
        }
        add("effects-glow-styles") { $0.effects = .init(glow: .init(enabled: true, amount: 65, style: $1 ? .halation : .bloom)) }
        add("effects-grain-amount") { $0.effects = .init(enabled: true, grain: $1 ? 0.5 : 0, grainSize: 0.25, grainRoughness: 0.25) }
        add("effects-grain-size") { $0.effects = .init(enabled: true, grain: 0.5, grainSize: $1 ? 0.65 : 0.25, grainRoughness: 0.25) }
        add("effects-grain-roughness") { $0.effects = .init(enabled: true, grain: 0.5, grainSize: 0.25, grainRoughness: $1 ? 0.65 : 0.25) }
        let vignetteFields: [(String, WritableKeyPath<DevelopmentPostCropVignetteV3, Double>, Double, Double)] = [
            ("amount", \.amount, 0, -50), ("midpoint", \.midpoint, 25, 65), ("roundness", \.roundness, 0, 60),
            ("feather", \.feather, 25, 65), ("highlights", \.highlights, 0, 80)]
        for (id, field, low, high) in vignetteFields {
            add("effects-pcv-" + id) { p, b in
                var value = DevelopmentPostCropVignetteV3(enabled: true, amount: -60)
                value[keyPath: field] = b ? high : low
                p.effects = .init(postCropVignette: value)
            }
        }
        add("effects-pcv-style") { $0.effects = .init(postCropVignette: .init(enabled: true, amount: -60, style: $1 ? .colorPriority : .highlightPriority)) }

        let bands: [(String, WritableKeyPath<DevelopmentParametricCurveV3, Double>)] = [
            ("highlights", \.highlights), ("lights", \.lights), ("darks", \.darks), ("shadows", \.shadows)]
        for (id, field) in bands {
            add("curve-param-" + id) { p, b in
                var curve = DevelopmentParametricCurveV3()
                curve[keyPath: field] = b ? 40 : 0
                p.curves = .init(enabled: true, parametric: curve)
            }
        }
        add("curve-param-splits") { $0.curves = .init(enabled: true, parametric: .init(darks: 40, split2: $1 ? 0.65 : 0.5)) }
        let bent = DevelopmentCurve(points: [.init(x: 0, y: 0), .init(x: 100/255, y: 145/255), .init(x: 1, y: 1)])
        add("curve-point") { $0.curves = .init(enabled: true, rgb: .init(curve: $1 ? bent : .init())) }
        add("curve-channels") { $0.curves = .init(enabled: true, red: .init(curve: $1 ? bent : .init())) }
        add("curve-refine-saturation") { $0.curves = .init(enabled: true, rgb: .init(curve: bent), refineSaturation: $1 ? 100 : 0) }
        let mixer: [(String, WritableKeyPath<DevelopmentSelectiveColorAdjustmentV3, Double>)] = [
            ("hue", \.hue), ("saturation", \.saturation), ("luminance", \.luminance)]
        for (id, field) in mixer {
            add("mixer-" + id) { p, b in
                p.selectiveColor.enabled = true
                if let index = p.selectiveColor.colors.firstIndex(where: { $0.slot == .blue }) {
                    p.selectiveColor.colors[index][keyPath: field] = b ? 40 : 0
                }
            }
        }
        add("mixer-visualize-range") { $0.selectiveColor = .init(enabled: true, visualiseRange: $1 ? .blue : nil) }
        add("mixer-isolate-hue") { $0.selectiveColor = .init(enabled: true, visualiseIsolation: $1 ? .blue : nil) }
        add("mixer-bw-mixer") { p, b in
            var values = Array(repeating: 0.0, count: 8)
            values[5] = b ? 0.5 : 0
            p.blackAndWhite = .init(enabled: true, mixer: .init(values: values))
        }
        let pointFields: [(String, WritableKeyPath<DevelopmentPointColorSampleV3, Double>)] = [
            ("hue", \.hue), ("saturation", \.saturation), ("luminance", \.luminance), ("range", \.range)]
        let pointID = UUID(uuidString: "AEAE804C-699A-4BBB-9CA5-4E26CEAA1941")!
        for (id, field) in pointFields {
            add("mixer-point-" + id) { p, b in
                var point = DevelopmentPointColorSampleV3(id: pointID, sampledColor: .init(red: 0.4, green: 0.25, blue: 0.18), hue: id == "range" ? 30 : 0)
                point[keyPath: field] = id == "range" ? (b ? 0.75 : 0.25) : (b ? 30 : 0)
                p.selectiveColor = .init(enabled: true, pointColors: [point])
            }
        }
        add("mixer-point-variance") { p, b in
            p.selectiveColor = .init(enabled: true, pointColors: [.init(id: pointID, sampledColor: .init(red: 0.4, green: 0.25, blue: 0.18),
                hue: 30, variance: b ? 45 : 0)])
        }
        add("detail-sharpen-amount") { $0.sharpen = .init(enabled: true, intensity: $1 ? 0.75 : 0, radius: 1.0, detail: 0.25) }
        add("detail-sharpen-radius") { $0.sharpen = .init(enabled: true, intensity: 0.75, radius: $1 ? 2 : 0.8, detail: 0.25) }
        add("detail-sharpen-detail") { $0.sharpen = .init(enabled: true, intensity: 0.75, radius: 1, detail: $1 ? 0.7 : 0.1) }
        add("detail-sharpen-masking") { $0.sharpen = .init(enabled: true, intensity: 0.75, radius: 1, masking: $1 ? 0.75 : 0) }
        add("detail-mask-preview") { $0.sharpen = .init(enabled: true, intensity: 0.75, radius: 1, masking: 0.6, visualiseMasking: $1) }
        add("detail-nr-luminance") { $0.noiseReduction = .init(enabled: true, luminanceNoise: $1 ? 0.7 : 0) }
        add("detail-nr-color") { $0.noiseReduction = .init(enabled: true, colorNoise: $1 ? 0.7 : 0) }
        add("detail-nr-lum-detail") { $0.noiseReduction = .init(enabled: true, luminanceNoise: 0.7, detail: $1 ? 0.65 : 0.1) }
        add("detail-nr-lum-contrast") { $0.noiseReduction = .init(enabled: true, luminanceContrast: $1 ? 0.8 : 0) }
        add("detail-nr-color-detail") { $0.noiseReduction = .init(enabled: true, colorDetail: $1 ? 0.8 : 0.1) }

        let wheels: [(String, WritableKeyPath<DevelopmentColorGrading, DevelopmentGradingWheel>)] = [
            ("shadows", \.shadows), ("midtones", \.midtones), ("highlights", \.highlights), ("global", \.global)]
        for (id, field) in wheels {
            add("grading-" + id) { p, edited in
                var grading = DevelopmentColorGrading()
                grading[keyPath: field] = .init(hueDegrees: 220, saturation: edited ? 50 : 0)
                p.legacyBasis = .init(version: .v2, color: .init(grading: grading))
            }
        }
        for id in ["grading-luminance", "grading-blending", "grading-balance"] {
            add(id) { p, edited in
                var grading = DevelopmentColorGrading(shadows: .init(hueDegrees: 25, saturation: 50),
                                                    highlights: .init(hueDegrees: 220, saturation: 55))
                if id == "grading-luminance" { grading.shadows.luminance = edited ? 40 : 0 }
                if id == "grading-blending" { grading.blending = edited ? 85 : 25 }
                if id == "grading-balance" { grading.balance = edited ? 60 : 0 }
                p.legacyBasis = .init(version: .v2, color: .init(grading: grading))
            }
        }

        let maskID = UUID(uuidString: "AF3D2501-A700-4803-AC2D-5920522C4FC2")!
        func masked(_ id: String, _ update: (inout DevelopmentMaskAdjustmentsV3, Bool) -> Void) {
            add(id) { p, b in
                var value = DevelopmentMaskAdjustmentsV3()
                update(&value, b)
                p.masks = [.init(id: maskID, name: "Benchmark", kind: .radial, feather: 0.5, adjustments: value)]
            }
        }
        let nonOptionalLocal: [(String, WritableKeyPath<DevelopmentMaskAdjustmentsV3, Double>)] = [
            ("light-mask-exposure", \.exposure), ("light-mask-highlights", \.highlights), ("light-mask-shadows", \.shadows),
            ("color-mask-saturation", \.saturation)]
        for (id, field) in nonOptionalLocal { masked(id) { $0[keyPath: field] = $1 ? 0.35 : 0 } }
        let local: [(String, WritableKeyPath<DevelopmentMaskAdjustmentsV3, Double?>)] = [
            ("light-mask-whites", \.whites), ("light-mask-blacks", \.blacks), ("light-mask-contrast", \.contrast),
            ("color-mask-temp", \.temperature), ("color-mask-tint", \.tint), ("color-mask-hue", \.hue),
            ("effects-mask-texture", \.texture), ("effects-mask-clarity", \.clarity), ("effects-glow-mask", \.glowAmount),
            ("effects-mask-grain", \.grain), ("detail-mask-sharpness", \.sharpness), ("detail-mask-noise", \.noiseReduction),
            ("detail-mask-moire", \.moireReduction), ("optics-local-defringe", \.defringe)]
        for (id, field) in local { masked(id) { $0[keyPath: field] = $1 ? 0.6 : 0 } }
        masked("color-mask-colorize") { $0.colorize = .init(red: 0.8, green: 0.5, blue: 0.1); $0.colorizeAmount = $1 ? 0.65 : 0 }
        masked("curve-mask-curve") { $0.curves = .init(enabled: true, rgb: .init(curve: $1 ? bent : .init())) }
        masked("grading-mask-wheels") { $0.grading = .init(midtones: .init(hueDegrees: 220, saturation: $1 ? 50 : 0)) }
        masked("mixer-point-mask") { $0.pointColor = .init(id: pointID, sampledColor: .init(red: 0.4, green: 0.25, blue: 0.18), hue: $1 ? 30 : 0) }

        add("optics-remove-ca") { $0.optics = .init(removeChromaticAberration: $1) }
        add("optics-manual-distortion") { $0.optics = .init(distortion: $1 ? 0.3 : 0) }
        add("optics-lens-vignette-amount") { $0.optics = .init(lensVignettingAmount: $1 ? 0.5 : 0, lensVignettingMidpoint: 0.5) }
        add("optics-lens-vignette-midpoint") { $0.optics = .init(lensVignettingAmount: 0.5, lensVignettingMidpoint: $1 ? 0.7 : 0.25) }
        let profile = DevelopmentLensProfileCatalogV3.profiles.first { $0.id == "sony-fe-14-gm" }
        add("optics-profile-enable") { $0.optics = .init(lensProfileEnabled: $1, lensProfile: profile) }
        add("optics-profile-distortion") { $0.optics = .init(lensProfileEnabled: true, lensProfile: profile, profileDistortionAmount: $1 ? 1 : 0) }
        add("optics-profile-vignetting") { $0.optics = .init(lensProfileEnabled: true, lensProfile: profile, profileVignettingAmount: $1 ? 1 : 0) }
        add("optics-purple-amount") { $0.optics = .init(defringe: .init(enabled: true, purpleAmount: $1 ? 65 : 0)) }
        add("optics-green-amount") { $0.optics = .init(defringe: .init(enabled: true, greenAmount: $1 ? 65 : 0)) }
        add("optics-purple-hue") { $0.optics = .init(defringe: .init(enabled:true, purpleAmount:65, purpleHueLower:$1 ? 290 : 230)) }
        add("optics-green-hue") { $0.optics = .init(defringe: .init(enabled:true, greenAmount:65, greenHueLower:$1 ? 120 : 50)) }
        add("blur-apply") { $0.effects = .init(lensBlur: .init(enabled: $1, amount: 0.65)) }
        add("blur-amount") { $0.effects = .init(lensBlur: .init(enabled: true, amount: $1 ? 0.75 : 0.1)) }
        add("blur-focus-range") { $0.effects = .init(lensBlur: .init(enabled: true, amount: 0.65, focusRange: $1 ? 0.6 : 0.15)) }
        add("blur-bokeh") { $0.effects = .init(lensBlur: .init(enabled: true, amount: 0.65, bokehStyle: $1 ? .fiveBlade : .circle)) }
        add("blur-cat-eye") { $0.effects = .init(lensBlur: .init(enabled: true, amount: 0.65, catEyeAmount: $1 ? 0.75 : 0)) }
        add("blur-boost") { $0.effects = .init(lensBlur: .init(enabled: true, amount: 0.65, bokehBoost: $1 ? 0.75 : 0)) }
        add("blur-visualize-depth") { $0.effects = .init(lensBlur: .init(enabled: true, amount: 0.65, visualiseDepth: $1)) }
        addBlurRefinementControls(add)
        if let mode = facts.rawDetailsCapability {
            add("detail-raw-details") { $0.rawDetails = $1 ? mode : nil }
        }
        if let model = facts.aiDenoiseCapability {
            add("detail-denoise") { $0.aiDenoise = .init(model: model, amount: $1 ? 100 : 0) }
        }
        addGradingLUTControls(add)
        return cases
    }

    private func witness(_ frame: DevelopmentPreviewFrame) throws -> (String, Int, Int) {
        let image = try XCTUnwrap(frame.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let side = 192
        let cg = try XCTUnwrap(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: PhotoRenderer.sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        cg.interpolationQuality = .high
        cg.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let bytes = Data(bytes: try XCTUnwrap(cg.data), count: side * side * 4)
        guard stride(from: 3, to: bytes.count, by: 4).allSatisfy({ bytes[$0] == 255 }) else { throw DevelopmentError.unreadable }
        return (SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), image.width, image.height)
    }

    func testChangedControlsOnResidentRAW() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_CONTROL_RAW"], let output = env["RAWMASTER_CONTROL_REPORT"] else {
            throw XCTSkip("Individual control benchmarking requires a real RAW and a fresh output path")
        }
        #if DEBUG
        throw XCTSkip("Use a release build for timings")
        #endif
        let url = URL(fileURLWithPath: path), destination = URL(fileURLWithPath: output)
        guard !FileManager.default.fileExists(atPath: output) else { throw CocoaError(.fileWriteFileExists) }
        let hash = try RenderFiles.hash(url)
        let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
        let source = EditingSourceSnapshot(projectID: "individual-controls", assetID: "work-copy",
            contentSHA256: hash, byteCount: Int64(try XCTUnwrap(bytes)), admissionFingerprint: "control-benchmark-v1", sourceLocation: url)
        let decoder = try XCTUnwrap(DevelopmentRAWSourcePolicy.decoderForNewWork(at: url))
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 1_073_741_824, interactiveEvaluation: .proxyV1))
        let session = try await service.open(source: .raw(source)), consumer = PreviewConsumerID()
        do {
            let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
            ImageEnginePrewarming.run()
            var catalog = try controls(decoder: decoder, facts: facts)
            let selected = Set((env["RAWMASTER_CONTROL_ONLY"] ?? "").split(separator: ",").map(String.init))
            if selected.isEmpty || selected.contains(where: { $0.hasPrefix("blur-") }) {
                let depth = try await ImageEngines.sceneDepth.estimate(source)
                catalog = catalog.map { control in
                    guard control.id.hasPrefix("blur-") else { return control }
                    let states = control.states.map { state in
                        var recipe = state
                        recipe.adjustmentsV3?.effects?.lensBlur?.sceneDepth = depth
                        return recipe
                    }
                    return Control(id:control.id, states:states)
                }
            }
            var preparationMs: Double?
            if selected.isEmpty || selected.contains("effects-dehaze") {
                let context = try XCTUnwrap(facts.dehazeContextV1)
                var payload = DevelopmentAdjustmentsV3()
                payload.rawDecoder = decoder
                let projection = try DevelopmentRecipe(adjustmentsV3:payload).prospectiveDehazeInputV1(context:context, algorithm:.positiveColorGuideV2)
                let request = DevelopmentPreviewRequest(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                    consumerID: PreviewConsumerID(), role:.primary, revision:1, recipe:projection.analysisRecipe,
                    quality:.settled, viewport:.init(maxPixel:2400))
                let start = DispatchTime.now().uptimeNanoseconds
                let result = try await service.analyze(.init(preview:request, expectedRecipeFingerprint:projection.expectedRecipeFingerprint,
                    stage:.workingImageBeforeGeometry, operation:.prepareDehaze, presentedRecipeFingerprint:projection.presentedRecipeFingerprint,
                    dehazeInputV1:projection.input))
                preparationMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                guard case .dehaze(let model) = result.value, case .prepared(let prepared) = model.resolution else {
                    throw DevelopmentDehazePreparationError.invalidPreparation
                }
                payload.advancedDetail.preparedDehaze = prepared
                payload.advancedDetail.dehazeAlgorithmVersion = prepared.algorithmVersion
                payload.advancedDetail.dehaze = .init(enabled:true, amount:15)
                let first = DevelopmentRecipe(adjustmentsV3:payload)
                payload.advancedDetail.dehaze.amount = 45
                catalog.append(.init(id:"effects-dehaze", states:[first, .init(adjustmentsV3:payload)]))
            }
            let repeats = Int(env["RAWMASTER_CONTROL_SAMPLES"] ?? "") ?? 20
            guard (2...100).contains(repeats), selected.isSubset(of: Set(catalog.map(\.id))) else { throw EditingError.invalidRecipe }
            var revision: UInt64 = 0
            var rows: [[String: Any]] = []
            for item in catalog where selected.isEmpty || selected.contains(item.id) {
                var samples: [[String: Any]] = []
                var seen = [Set<String>(), Set<String>()]
                var width = 0, height = 0
                var row: [String: Any] = ["id": item.id, "status": "inconclusive"]
                do {
                    if item.id == "detail-denoise", let model = facts.aiDenoiseCapability {
                        let start = DispatchTime.now().uptimeNanoseconds
                        try await DevelopmentNeuralRaw9.prepare(at:url, model:model)
                        row["prepareModelMs"] = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                    }
                    for recipe in item.states { try recipe.validate() }
                    row["decoders"] = item.states.map { recipe in
                        if let neural = recipe.adjustmentsV3?.aiDenoise { return neural.model.rawValue }
                        return recipe.adjustmentsV3.map { DevelopmentRAWSourcePolicy.usesFlashRaw($0) ? decoder.rawValue : "CIRAWFilter" } ?? "CIRAWFilter"
                    }
                    if item.id == "effects-dehaze" { row["prepareAnalysisMs"] = preparationMs }
                    row["recipes"] = try item.states.map { try EditingFingerprint.of($0) }
                    for n in 0..<(repeats + 2) {
                        let state = n % 2
                        revision += 1
                        let request = DevelopmentPreviewRequest(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                            consumerID: consumer, role: .primary, revision: revision, recipe: item.states[state],
                            quality: .interactive, viewport: .init(maxPixel: 2400))
                        let start = DispatchTime.now().uptimeNanoseconds
                        let frame = try await service.render(request)
                        let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                        let (digest, w, h) = try witness(frame)
                        if width != 0 && (width != w || height != h) { throw DevelopmentError.unreadable }
                        width = w; height = h
                        seen[state].insert(digest)
                        samples.append(["state": state, "phase": n < 2 ? "first" : "warm", "ms": ms, "digest": digest,
                                        "approximate": frame.approximate])
                    }
                    if seen[0].count == 1 && seen[1].count == 1 && seen[0] != seen[1] { row["status"] = "measured" }
                    else { row["reason"] = "Control/edit thumbnails did not yield stable distinct RGB pixels" }
                } catch { row["reason"] = String(describing: error) }
                row["samples"] = samples
                row["outputPixels"] = [width, height]
                rows.append(row)
                print("CONTROL \(item.id) \(row["status"]!)")
            }
            let after = try RenderFiles.hash(url)
            XCTAssertEqual(hash, after)
            let binary = try XCTUnwrap(Bundle(for:Self.self).executableURL)
            let report: [String: Any] = ["schemaVersion": 1, "protocol": "rawmaster-resident-control-v1",
                "build": "release", "binarySHA256": try RenderFiles.hash(binary), "recordedAt":ISO8601DateFormatter().string(from: Date()),
                "physicalMemory": ProcessInfo.processInfo.physicalMemory, "completeCatalog": selected.isEmpty, "os": ProcessInfo.processInfo.operatingSystemVersionString,
                "gpu": MTLCreateSystemDefaultDevice()?.name ?? "unknown", "decoder": decoder.rawValue,
                "sourceSHA256": hash, "sourceSHA256After": after, "repeats": repeats,
                "requestedPixels": 2400, "boundary": "Changed recipe request to interactive ImageEngine frame return; RGB readback outside timer",
                "operations": rows]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: destination, options: .withoutOverwriting)
            await service.close(session.id)
        } catch { await service.close(session.id); throw error }
    }
}

extension IndividualControlPerformanceTests {
    /// The same CPU-readable, full fitted sRGB display target used by LightFlow's stock viewerReadback.
    func testPairedDisplayReadback() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["RAWMASTER_PAIRED_READBACK_RAW"], let output = env["RAWMASTER_PAIRED_READBACK_REPORT"] else {
            throw XCTSkip("Set the paired display RAW and evidence path")
        }
        #if DEBUG
        throw XCTSkip("Readback comparisons require a Release build")
        #endif
        let url = URL(fileURLWithPath:path), sha = try RenderFiles.hash(url)
        let byteCount = try XCTUnwrap(url.resourceValues(forKeys:[.fileSizeKey]).fileSize)
        let source = EditingSourceSnapshot(projectID:"paired-display",assetID:"sony",contentSHA256:sha,
            byteCount:Int64(byteCount),admissionFingerprint:"paired-display-v1",sourceLocation:url)
        let engine = ImageEngines.editing
        let session = try await engine.open(source:.raw(source))
        do {
            let facts = try await engine.sourceFacts(sessionID:session.id,sourceGeneration:session.sourceGeneration)
            let decoder = try XCTUnwrap(DevelopmentRAWSourcePolicy.decoderForNewWork(at:url))
            let width = 2400, height = 1600, repeats = 20
            let consumer = PreviewConsumerID()
            let values: [String:[Double]] = ["light-exposure":[0,0.5], "light-contrast":[0,30], "light-highlights":[0,30],
                "light-shadows":[0,30], "light-whites":[0,30], "light-blacks":[0,-30], "color-saturation":[0,30], "color-vibrance":[0,30]]
            let fields: [String:WritableKeyPath<DevelopmentAdjustmentsV3,Double>] = ["light-exposure":\.light.exposure,
                "light-contrast":\.light.contrast, "light-highlights":\.light.highlights, "light-shadows":\.light.shadows,
                "light-whites":\.light.whites, "light-blacks":\.light.blackPoint, "color-saturation":\.color.saturation, "color-vibrance":\.color.vibrance]
            let target = UnsafeMutableRawBufferPointer.allocate(byteCount:width*height*4,alignment:64)
            defer { target.deallocate() }
            let buffer = try XCTUnwrap(target.baseAddress).assumingMemoryBound(to:UInt8.self)
            let savedFrames=env["RAWMASTER_PAIRED_READBACK_PIXEL_DIR"].map { URL(fileURLWithPath:$0,isDirectory:true) }
            if let savedFrames { try FileManager.default.createDirectory(at:savedFrames,withIntermediateDirectories:true) }
            var rows = [[String:Any]](), revision: UInt64 = 0
            ImageEnginePrewarming.run()
            for item in try controls(decoder:decoder,facts:facts) where values[item.id] != nil {
                var trials = [[String:Any]](), sweep = [[String:Any]](), seen = [Set<String>(),Set<String>()], unique = Set<String>()
                let factor = item.id == "light-exposure" ? 2.0 : (item.id == "light-blacks" ? -100.0 : 100.0)
                for i in 0..<(2*repeats+2) {
                    let state = i % 2
                    let level = i-repeats-1
                    var recipe = item.states[state]
                    let value = level > 0 ? Double(level)*(item.id == "light-exposure" ? 0.04 : (item.id == "light-blacks" ? -1 : 1))
                        : try XCTUnwrap(values[item.id])[state]
                    if level > 0 {
                        recipe = item.states[1]
                        let field = try XCTUnwrap(fields[item.id])
                        recipe.adjustmentsV3?[keyPath:field] = value/factor
                    }
                    revision += 1
                    let request = DevelopmentPreviewRequest(sessionID:session.id,sourceGeneration:session.sourceGeneration,
                        consumerID:consumer,role:.primary,revision:revision,recipe:recipe,quality:.interactive,viewport:.init(maxPixel:width))
                    let start = DispatchTime.now().uptimeNanoseconds
                    let frame = try await engine.render(request)
                    let ready = DispatchTime.now().uptimeNanoseconds
                    guard frame.outputPixelSize == CGSize(width:width,height:height) else { throw DevelopmentError.unreadable }
                    try frame.copyDisplayRGBA8(into:target)
                    let copied = DispatchTime.now().uptimeNanoseconds
                    let ms = Double(copied-start)/1_000_000
                    let transfer = Double(copied-ready)/1_000_000
                    if let savedFrames,(item.id == "light-highlights" || item.id == "light-shadows"),
                       i == 1 || level == 10 || level == repeats {
                        let name="\(item.id)-\(Int(value)).rgba8"
                        try Data(target).write(to:savedFrames.appendingPathComponent(name),options:.withoutOverwriting)
                    }
                    var pixels = Data(capacity:96*64*3)
                    for y in 0..<64 { for x in 0..<96 {
                        let offset = 4*((2*y+1)*height/128*width + (2*x+1)*width/192)
                        guard buffer[offset+3] == 255 else { throw DevelopmentError.unreadable }
                        pixels.append(buffer.advanced(by:offset),count:3)
                    }}
                    let digest = SHA256.hash(data:pixels).map { String(format:"%02x",$0) }.joined()
                    if level > 0 {
                        unique.insert(digest)
                        sweep.append(["value":value,"ms":ms,"transferMs":transfer,"digest":digest])
                    } else {
                        seen[state].insert(digest)
                        trials.append(["state":state,"phase":i<2 ? "first":"warm","ms":ms,"transferMs":transfer,"digest":digest])
                    }
                }
                let verified = seen.allSatisfy { $0.count == 1 } && seen[0] != seen[1] && unique.count == repeats
                rows.append(["id":item.id,"values":try XCTUnwrap(values[item.id]),"samples":trials,
                             "distinctInputs":sweep,"status":verified ? "measured":"inconclusive"])
                XCTAssertTrue(verified,item.id)
            }
            XCTAssertEqual(rows.count,values.count)
            let after = try RenderFiles.hash(url)
            XCTAssertEqual(after,sha)
            let evidence: [String:Any] = ["schemaVersion":1,"protocol":"resident-srgb8-readback-v1", "application":"RAWMaster",
                "cachePolicy":"shipping defaults", "distinctInputCount":repeats,
                "pixels":[width,height],"samples":repeats,"sourceSHA256":sha,"sourceSHA256After":after,"decoder":decoder.rawValue,
                "gpu":MTLCreateSystemDefaultDevice()?.name ?? "", "os":ProcessInfo.processInfo.operatingSystemVersionString,
                "recordedAt":ISO8601DateFormatter().string(from:Date()),"binarySHA256":try RenderFiles.hash(XCTUnwrap(Bundle(for:Self.self).executableURL)),
                "boundary":"Changed resident recipe to complete CPU-accessible sRGB RGBA8 display buffer; hash outside timer","operations":rows]
            try JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.withoutOverwriting)
            await engine.close(session.id)
        } catch { await engine.close(session.id); throw error }
    }

    private func addBlurRefinementControls(_ add: (String, (inout DevelopmentAdjustmentsV3, Bool) -> Void) -> Void) {
        let strokeID = UUID(uuidString: "56E79909-9098-47CC-B869-5D0EBCD6DDC9")!
        for operation in ["refine-focus", "refine-blur", "refine-amount", "brush-size", "feather", "flow", "auto-mask", "reset-refinement"] {
            add("blur-" + operation) { p, edited in
                let mode: DevelopmentLensBlurRefinementModeV3 = operation == "refine-blur" ? .blur : .focus
                let center = mode == .blur ? 0.5 : 0.22
                let stroke = DevelopmentStroke(points: [.init(position: .init(x: center, y: 0.45)),
                                                        .init(position: .init(x: center + 0.06, y: 0.53))],
                    radiusInShortEdge: operation == "brush-size" && !edited ? 0.06 : 0.16,
                    strength: operation == "refine-amount" && !edited ? 0.25 : 0.95)
                let refinement = DevelopmentLensBlurRefinementStrokeV3(id: strokeID, mode: mode, stroke: stroke,
                    feather: operation == "feather" && edited ? 0.85 : 0.15,
                    flow: operation == "flow" && !edited ? 0.15 : 0.95,
                    autoMask: operation == "auto-mask" && edited)
                var blur = DevelopmentLensBlurV3(enabled: true, amount: 0.9, focusRange: 0.05)
                switch operation {
                case "refine-focus", "refine-blur": blur.refinementStrokes = edited ? [refinement] : nil
                case "reset-refinement": blur.refinementStrokes = edited ? nil : [refinement]
                default: blur.refinementStrokes = [refinement]
                }
                p.effects = .init(lensBlur: blur)
            }
        }
    }

    private func addGradingLUTControls(_ add: (String, (inout DevelopmentAdjustmentsV3, Bool) -> Void) -> Void) {
        let first = DevelopmentLUTLayer(id: UUID(uuidString: "8f2d8a0a-20b6-41fc-a326-018358e549a1")!, cube: .warm)
        let second = DevelopmentLUTLayer(id: UUID(uuidString: "8f2d8a0a-20b6-41fc-a326-018358e549a2")!, cube: .monochrome)
        let third = DevelopmentLUTLayer(id: UUID(uuidString: "8f2d8a0a-20b6-41fc-a326-018358e549a3")!, cube: .warm, amount: 65)
        let maskID = UUID(uuidString: "8f2d8a0a-20b6-41fc-a326-018358e549a4")!
        add("grading-lut-select") { p, edited in
            var layer = first
            layer.cube = edited ? .monochrome : .warm
            p.gradingLUTs = .init(layers: [layer])
        }
        add("grading-lut-amount") { p, edited in
            var layer = second
            layer.amount = edited ? 85 : 25
            p.gradingLUTs = .init(layers: [layer])
        }
        add("grading-lut-stack") { p, edited in
            p.gradingLUTs = .init(layers: edited ? [first, second, third] : [first, second])
        }
        add("grading-lut-manage") { p, edited in
            p.gradingLUTs = .init(layers: edited ? [second, first] : [first, second])
        }
        add("grading-lut-mask") { p, edited in
            var layer = second
            layer.amount = edited ? 100 : 25
            p.masks = [.init(id: maskID, kind: .radial, feather: 0.2, adjustments: .init(gradingLUT: layer))]
        }
    }
}
