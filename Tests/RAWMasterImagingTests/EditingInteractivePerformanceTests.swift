import AppKit
import XCTest
import RAWMasterCore
@testable import RAWMasterImaging

/// Opt-in real-source measurement for the production proxy/canonical split.
/// This is deliberately not a Camera Raw benchmark: no Adobe presentation timing is inferred.
final class EditingInteractivePerformanceTests: XCTestCase {
    private struct Measurement: Codable {
        let label: String
        let effectiveDecoder: String
        let interactiveMilliseconds: [Double]
        let interactiveMedianMilliseconds: Double
        let settledMilliseconds: Double
        let approximate: Bool
        let width: Int
        let height: Int
        let settledWidth: Int
        let settledHeight: Int
        let qualityComparison: String
        let p99ChannelError: Int
        let maximumChannelError: Int
        /// Opt-in `RAWMASTER_INTERACTIVE_DETAIL=1`: the native 1:1 render for the same recipe.
        let detailMilliseconds: Double?
    }

    private func pixels(_ image: NSImage, fitting size: CGSize? = nil) throws -> (data: Data, width: Int, height: Int, stride: Int) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DevelopmentError.unreadable }
        let width = size.map { Int($0.width) } ?? cg.width, height = size.map { Int($0.height) } ?? cg.height
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: PhotoRenderer.sRGB,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
              let bytes = context.data else { throw DevelopmentError.unreadable }
        // Canonical output and interactive IOSurface output use different native channel orders.
        // Normalize both to RGBA before computing error; never compare BGRA bytes as RGB.
        context.setBlendMode(.copy)
        context.interpolationQuality = size == nil ? .none : .high
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        return (Data(bytes: bytes, count: width * height * 4), width, height, width * 4)
    }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }

    func testOptInRealRAWInteractivePerformanceAndSettledError() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RAWMASTER_INTERACTIVE_PERF"] == "1",
              let sourcePath = environment["RAWMASTER_INTERACTIVE_PERF_SOURCE"],
              let outputPath = environment["RAWMASTER_INTERACTIVE_PERF_OUTPUT"] else {
            throw XCTSkip("Explicit isolated source and output are required")
        }
        #if DEBUG
        throw XCTSkip("Release measurements required")
        #endif
        ImagePerformanceTelemetry.shared.reset()
        let prewarming = environment["RAWMASTER_INTERACTIVE_PREWARM"] == "1"
        if prewarming { ImageEnginePrewarming.run() }
        let flashRawAvailable = FlashRawSource.isAvailable
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let storedDecoder = try DevelopmentRAWSourcePolicy.decoderForNewWork(at: sourceURL)
        if environment["RAWMASTER_REQUIRE_FLASHRAW"] == "1", storedDecoder != .flashRaw031 { throw DevelopmentError.unsupportedEngine }
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reportURL = output.appendingPathComponent("interactive-performance.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reportURL.path), "Refuse to overwrite performance evidence")
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        let source = EditingSourceSnapshot(projectID: "interactive-performance", assetID: "fixed-raw",
            contentSHA256: try RenderFiles.hash(sourceURL), byteCount: try XCTUnwrap(attributes[.size] as? NSNumber).int64Value,
            admissionFingerprint: "interactive-performance-v1", sourceLocation: sourceURL)
        let rawBaseCacheBytes = environment["RAWMASTER_INTERACTIVE_RAW_BASE_CACHE"] == "1" ? 1_073_741_824:0
        // Product construction keeps a 128 MB display cache, so a settled frame for an
        // unchanged recipe replays the gesture frame instead of re-running the suffix.
        let bitmapCacheBytes = Int(environment["RAWMASTER_INTERACTIVE_BITMAP_CACHE"] ?? "0") ?? 0
        // Match the shipped policy: the settled canvas frame uses the viewport-resolution graph.
        // RAWMASTER_INTERACTIVE_SETTLED_TRANSPORT=canonical reproduces the previous native render.
        let settledTransport: PreviewSettledTransport = environment["RAWMASTER_INTERACTIVE_SETTLED_TRANSPORT"] == "canonical" ? .canonical : .viewport
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: bitmapCacheBytes, rawBaseCacheBytes: rawBaseCacheBytes, interactiveEvaluation: .proxyV1, settledTransport: settledTransport))
        // The viewport transport publishes the gesture pixels as the settled frame, so the
        // settled-vs-gesture error would be zero by construction. Keep a second session on the
        // native transport to measure the real deviation the caller accepts.
        let referenceService = settledTransport == .viewport
            ? DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0, rawBaseCacheBytes: 0,
                interactiveEvaluation: .canonical, settledTransport: .canonical)) : nil
        let referenceConsumer = PreviewConsumerID()
        var referenceSession: PreviewSessionInfo?
        if let referenceService { referenceSession = try await referenceService.open(source: .raw(source)) }
        let consumer = PreviewConsumerID()
        let session = try await service.open(source: .raw(source))
        let dehazeContext = try DevelopmentDehazeContextFactoryV1.fromCapture(sourceURL, generation: session.sourceGeneration)
        let facts = try await service.sourceFacts(sessionID: session.id, sourceGeneration: session.sourceGeneration)
        let baseline = try DevelopmentWhiteBalanceEngineV3.initialState(source: facts.sourceBinding, rawDefault: facts.asShotWhiteBalance)
        guard case .raw(_, var presetRaw) = baseline else { throw DevelopmentError.unreadable }
        presetRaw.selectedMode = .temperatureTint
        presetRaw.temperatureTint = .init(temperature: 6000, tint: 0)
        let flashPreset = DevelopmentResolvedWhiteBalanceV3.raw(source: facts.sourceBinding, state: presetRaw)
        var neutral = DevelopmentAdjustmentsV3()
        neutral.rawDecoder = storedDecoder
        let neutralRecipe = DevelopmentRecipe(adjustmentsV3: neutral)
        // Synthetic device-map input over a real RAW image; the ARW itself does not contain device depth.
        let syntheticDeviceDepth = try DevelopmentLensBlurDepthPayloadV1(kind: .depth, width: 64, height: 43,
            values: (0..<(64 * 43)).map { Float($0 % 64) / 63 })
        let focusRefinement = DevelopmentLensBlurRefinementStrokeV3(mode:.focus,stroke:.init(points:[.init(position:.init(x:0.2,y:0.5))],radiusInShortEdge:0.08),feather:0.3,flow:0.5)
        let blurRefinement = DevelopmentLensBlurRefinementStrokeV3(mode:.blur,stroke:.init(points:[.init(position:.init(x:0.5,y:0.5))],radiusInShortEdge:0.08),feather:0.3,flow:0.5)
        let autoMaskRefinement = DevelopmentLensBlurRefinementStrokeV3(mode:.focus,stroke:.init(points:[.init(position:.init(x:0.2,y:0.5))],radiusInShortEdge:0.08),feather:0.3,flow:0.5,autoMask:true)
        let targetedHSL = try DevelopmentTargetedColorAdjustmentV3.apply(initial:.init(),sample:.init(red:0.8,green:0.1,blue:0.1),mode:.saturation,drag:0.5)
        var targetedCurveChannel=DevelopmentCurveChannelV3()
        targetedCurveChannel.curve = .init(points:[.init(x:0,y:0),.init(x:0.5,y:0.4),.init(x:1,y:1)])
        var targetedCurve=DevelopmentCurvesV3();targetedCurve.rgb=targetedCurveChannel
        let targetedPointCurve = try DevelopmentTargetedCurveAdjustmentV3.applyPoint(initial:targetedCurve,channel:.rgb,pointIndex:1,translation:.init(x:0.1,y:0.2))
        var revision: UInt64 = 0

        func recipe(_ label: String, dehazeAlgorithm: DevelopmentDehazeAlgorithm? = nil,
                    mutate: (inout DevelopmentAdjustmentsV3) -> Void) throws -> (String, DevelopmentRecipe) {
            var parameters = neutral
            mutate(&parameters)
            if let dehazeAlgorithm {
                let projection = try neutralRecipe.prospectiveDehazeInputV1(context: dehazeContext, algorithm: dehazeAlgorithm)
                parameters.advancedDetail.preparedDehaze = .init(sourceBinding: dehazeContext.source,
                    inputFingerprint: projection.input.inputFingerprint, airlight: .init(red: 0.5, green: 0.75, blue: 1),
                    algorithmVersion: dehazeAlgorithm.rawValue)
            }
            return (label, DevelopmentRecipe(adjustmentsV3: parameters))
        }
        var recipes = [
            try recipe("neutral") { _ in },
            try recipe("exposure-color") { value in
                value.light.enabled = true; value.light.exposure = 0.35
                value.color.enabled = true; value.color.saturation = 0.3; value.color.vibrance = 0.15
            },
            try recipe("adaptive-brilliance") { value in
                value.light = .init(enabled: true, brilliance: 0.35, brillianceVersion: .adaptiveLocalV1)
            },
            try recipe("texture") { value in value.advancedDetail.texture = .init(enabled: true, amount: 25) },
            try recipe("clarity") { value in value.advancedDetail.clarity = .init(enabled: true, amount: 25) },
            try recipe("dehaze-v1", dehazeAlgorithm: .v1) { value in
                value.advancedDetail.dehaze = .init(enabled: true, amount: 25)
            },
            try recipe("dehaze-v2", dehazeAlgorithm: .positiveColorGuideV2) { value in
                value.advancedDetail.dehaze = .init(enabled: true, amount: 25)
            },
            try recipe("geometry") { value in
                value.geometry.straightenDegrees = 2
                value.geometry.crop = .init(x: 0.08, y: 0.06, width: 0.84, height: 0.88)
            },
            try recipe("post-crop-vignette") { value in
                value.geometry.straightenDegrees = 2
                value.geometry.crop = .init(x: 0.08, y: 0.06, width: 0.84, height: 0.88)
                value.effects = .init(postCropVignette: .init(enabled: true, amount: -55,
                    style: .highlightPriority, midpoint: 45, roundness: 20, feather: 55, highlights: 75))
            },
            try recipe("lens-blur-procedural") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25))
            },
            try recipe("lens-blur-device-depth") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,deviceDepth:syntheticDeviceDepth))
            },
            try recipe("lens-blur-refine-focus") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.5,focusY:0.5,focusRange:0.1,refinementStrokes:[focusRefinement]))
            },
            try recipe("lens-blur-refine-blur") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.5,focusY:0.5,focusRange:0.1,refinementStrokes:[blurRefinement]))
            },
            try recipe("lens-blur-refine-auto-mask") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.5,focusY:0.5,focusRange:0.1,refinementStrokes:[autoMaskRefinement]))
            },
            try recipe("lens-blur-bokeh-bubble") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,bokehStyle:.bubble))
            },
            try recipe("lens-blur-bokeh-five-blade") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,bokehStyle:.fiveBlade))
            },
            try recipe("lens-blur-bokeh-ring") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,bokehStyle:.ring))
            },
            try recipe("lens-blur-bokeh-anamorphic") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,bokehStyle:.anamorphic))
            },
            try recipe("lens-blur-cat-eye") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,bokehStyle:.fiveBlade,catEyeAmount:0.7))
            },
            try recipe("lens-blur-bokeh-boost") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0.65,focusX:0.4,focusY:0.6,focusRange:0.25,bokehStyle:.bubble,bokehBoost:0.7))
            },
            try recipe("lens-blur-depth-preview") { value in
                value.effects = .init(lensBlur:.init(enabled:true,amount:0,focusX:0.4,focusY:0.6,focusRange:0.25,visualiseDepth:true))
            },
            try recipe("local-glow") { value in
                value.effects = .init(glow: .init(enabled: false, amount: 0, style: .halation,
                    range: 70, spread: 35, warmth: 60))
                value.masks = [.init(name: "局部光晕性能", kind: .radial,
                    adjustments: .init(glowAmount: 0.55))]
            },
            try recipe("bw-mixer") { value in
                value.blackAndWhite = .init(enabled: true, mixer: .init(values: [
                    0.35,-0.2,0.25,0.15,-0.1,0.3,-0.25,0.2
                ]))
            },
            try recipe("point-variance") { value in
                value.selectiveColor.enabled = true
                value.selectiveColor.colors[0].sampledColor = .init(red: 0.4, green: 0.2, blue: 0.15)
                value.selectiveColor.colors[0].variance = 45
                value.selectiveColor.colors[0].hue = 10
                value.selectiveColor.colors[0].saturation = 5
            },
            try recipe("targeted-hsl") { value in
                value.selectiveColor = targetedHSL
            },
            try recipe("visualise-range") { value in
                value.selectiveColor.enabled = true
                value.selectiveColor.visualiseRange = .red
            },
            try recipe("hue-isolation") { value in
                value.selectiveColor.enabled = true
                value.selectiveColor.visualiseIsolation = .red
            },
            try recipe("clipping-shadows") { value in value.light.clippingPreview = .shadows },
            try recipe("clipping-highlights") { value in value.light.clippingPreview = .highlights },
            try recipe("wb-flash-preset") { value in
                value.whiteBalance = .init(enabled: true, resolvedState: flashPreset)
            },
            try recipe("refine-saturation") { value in
                value.curves.enabled = true
                value.curves.rgb.curve = .init(points: [.init(x:0,y:0),.init(x:0.25,y:0.32),.init(x:1,y:1)])
                value.curves.refineSaturation = 25
            },
            try recipe("point-curve-targeted") { value in value.curves = targetedPointCurve },
            try recipe("defringe") { value in
                value.optics = .init(defringe: .init(enabled: true, purpleAmount: 60, greenAmount: 40))
            },
            try recipe("point-color-samples") { value in
                value.selectiveColor.enabled = true
                value.selectiveColor.pointColors = [
                    .init(sampledColor:.init(red:0.4,green:0.2,blue:0.15),hue:20,saturation:15,range:0.6),
                    .init(sampledColor:.init(red:0.12,green:0.3,blue:0.5),hue:-15,luminance:20,range:0.5,variance:20)
                ]
            },
            try recipe("local-point-color") { value in
                value.masks = [.init(name:"局部点颜色性能",kind:.radial,feather:0.35,
                    adjustments:.init(exposure:0.1,pointColor:.init(
                        sampledColor:.init(red:0.4,green:0.2,blue:0.15),
                        hue:20,saturation:15,range:0.6,variance:20)))]
            },
            try recipe("local-light-extended") { value in
                value.masks = [.init(name:"局部Light性能",kind:.radial,feather:0.35,
                    adjustments:.init(contrast:0.25,whites:0.2,blacks:-0.15))]
            },
            try recipe("local-wb") { value in
                value.masks = [.init(name:"局部色温性能",kind:.radial,feather:0.35,
                    adjustments:.init(temperature:0.2,tint:-0.15))]
            },
            try recipe("local-hue-colorize") { value in
                value.masks = [.init(name:"局部色相着色性能",kind:.radial,feather:0.35,
                    adjustments:.init(hue:0.2,fineAdjustment:true,
                        colorize:.init(red:0.8,green:0.1,blue:0.05),colorizeAmount:0.6))]
            },
            try recipe("local-texture-clarity") { value in
                value.masks = [.init(name:"局部频带性能",kind:.radial,feather:0.35,
                    adjustments:.init(texture:0.3,clarity:0.2))]
            },
            try recipe("local-dehaze") { value in
                value.masks = [.init(name:"局部去雾性能",kind:.radial,feather:0.35,
                    adjustments:.init(dehaze:0.35))]
            },
            try recipe("local-grain") { value in
                value.masks = [.init(name:"局部颗粒性能",kind:.radial,feather:0.35,
                    adjustments:.init(grain:0.5,grainSize:0.4,grainRoughness:0.6))]
            },
            try recipe("local-curves") { value in
                let curve=DevelopmentCurve(points:[.init(x:0,y:0),.init(x:0.25,y:0.36),.init(x:1,y:1)])
                value.masks = [.init(name:"局部曲线性能",kind:.radial,feather:0.35,
                    adjustments:.init(curves:.init(enabled:true,rgb:.init(curve:curve))))]
            },
            try recipe("local-grading") { value in
                let grading=DevelopmentColorGrading(shadows:.init(hueDegrees:30,saturation:35,luminance:8),
                    midtones:.init(hueDegrees:200,saturation:20),highlights:.init(hueDegrees:300,saturation:25,luminance:5),
                    global:.init(hueDegrees:100,saturation:10),blending:60,balance:20)
                value.masks = [.init(name:"局部色彩分级性能",kind:.radial,feather:0.35,adjustments:.init(grading:grading))]
            },
            try recipe("local-detail") { value in
                value.masks = [.init(name:"局部细节性能",kind:.radial,feather:0.35,
                    adjustments:.init(sharpness:0.25,noiseReduction:0.2,moireReduction:0.3))]
            },
            try recipe("local-defringe") { value in
                value.optics = .init(defringe:.init(enabled:true,purpleAmount:60,greenAmount:40))
                value.masks = [
                    .init(name:"局部去边性能",kind:.radial,center:.init(x:0.35,y:0.5),radiusX:0.25,radiusY:0.3,feather:0.25,adjustments:.init(defringe:0.7)),
                    .init(name:"去边保护性能",kind:.radial,center:.init(x:0.7,y:0.5),radiusX:0.2,radiusY:0.25,feather:0.2,adjustments:.init(defringe:-1))
                ]
            },
            try recipe("global-sharpen-detail") { value in
                value.sharpen = .init(enabled:true,intensity:0.8,edges:0.22,falloff:0.69,radius:1.4,detail:0.65,masking:0.35)
            },
            try recipe("global-sharpen-mask-preview") { value in
                value.sharpen = .init(enabled:true,intensity:0,radius:1.4,detail:0.65,masking:0.35,visualiseMasking:true)
            },
            try recipe("global-noise-detail") { value in
                value.noiseReduction = .init(enabled:true,sourceCapability:.raw,luminanceContrast:0.4,colorDetail:0.6)
            },
            try recipe("optics-ca-distortion") { value in
                value.optics = .init(removeChromaticAberration:true,distortion:0.15)
            },
            try recipe("optics-lens-profile") { value in
                let profile=DevelopmentLensProfileCatalogV3.profiles[1]
                value.optics = .init(lensProfileEnabled:true,lensProfile:profile,profileDistortionAmount:0.8,profileVignettingAmount:0.7,
                    lensVignettingAmount:0.4,lensVignettingMidpoint:0.6)
            }
        ]
        if environment["RAWMASTER_INTERACTIVE_SHARP_MASK_SWEEP"] == "1" {
            for percent in [15,60,90] {
                recipes.append(try recipe("native-sharpen-mask-\(percent)") { value in
                    value.sharpen = .init(enabled:true,intensity:0,radius:1.4,detail:0.65,masking:Double(percent)/100,visualiseMasking:true)
                })
            }
        }
        var measurements: [Measurement] = []
        var transparentFrameFailures: [String] = []
        let selectedCases=Set((environment["RAWMASTER_INTERACTIVE_PERF_ONLY"] ?? "").split(separator:",").map(String.init))
        let outputCases=Set((environment["RAWMASTER_INTERACTIVE_WRITE_CASE"] ?? "").split(separator:",").map(String.init))
        do {
            for (label, recipe) in recipes where selectedCases.isEmpty || selectedCases.contains(label) {
                print("INTERACTIVE-CASE \(label)")
                var interactiveTimes: [Double] = []
                var interactive: DevelopmentPreviewFrame?
                for iteration in 0..<3 {
                    revision += 1
                    let started = DispatchTime.now().uptimeNanoseconds
                    interactive = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                        consumerID: consumer, role: .primary, revision: revision, recipe: recipe,
                        quality: .interactive, viewport: .init(maxPixel: 2400)))
                    interactiveTimes.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    print("INTERACTIVE-FRAME \(label) \(iteration) \(interactiveTimes.last ?? 0)")
                }
                let interactiveFrame = try XCTUnwrap(interactive)
                revision += 1
                print("SETTLED-CASE \(label)")
                let settledStarted = DispatchTime.now().uptimeNanoseconds
                let settled = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                    consumerID: consumer, role: .primary, revision: revision, recipe: recipe,
                    quality: .settled, viewport: .init(maxPixel: 2400)))
                let settledTime = Double(DispatchTime.now().uptimeNanoseconds - settledStarted) / 1_000_000
                // `published` is the frame the caller receives; `reference` is the native render it
                // replaces. Under the canonical transport both are the same frame, which keeps the
                // historical proxy-vs-native comparison.
                let published = settled
                let reference: DevelopmentPreviewFrame
                if let referenceSession {
                    reference = try await referenceService!.render(.init(sessionID: referenceSession.id,
                        sourceGeneration: referenceSession.sourceGeneration, consumerID: referenceConsumer,
                        role: .primary, revision: revision, recipe: recipe,
                        quality: .settled, viewport: .init(maxPixel: 2400)))
                } else { reference = published }
                let a = try pixels(interactiveFrame.image)
                let sameCanvas = reference.canonicalPixelSize == interactiveFrame.canonicalPixelSize
                guard sameCanvas else { throw DevelopmentError.invalidEncoding }
                let referenceSize = CGSize(width: a.width,height: a.height)
                let b = try pixels(reference.image,fitting:reference.outputPixelSize == referenceSize ? nil : referenceSize)
                let interactiveHasAlpha=stride(from:3,to:a.data.count,by:4).contains{a.data[$0]>0}
                let settledHasAlpha=stride(from:3,to:b.data.count,by:4).contains{b.data[$0]>0}
                if !interactiveHasAlpha { transparentFrameFailures.append(label+":interactive") }
                if !settledHasAlpha { transparentFrameFailures.append(label+":settled") }
                XCTAssertTrue(interactiveHasAlpha,"Interactive output is entirely transparent: \(label)")
                XCTAssertTrue(settledHasAlpha,"Settled output is entirely transparent: \(label)")
                if environment["RAWMASTER_INTERACTIVE_WRITE_IMAGES"] == "1",
                   label == "neutral" || outputCases.contains(label) {
                    for (name,frame) in [("interactive",interactiveFrame.image),("settled",published.image),("reference",reference.image)] {
                        guard let cg=frame.cgImage(forProposedRect:nil,context:nil,hints:nil),
                          let data=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:])else{throw DevelopmentError.unreadable}
                        try data.write(to:output.appendingPathComponent("\(label)-\(name).png"),options:.withoutOverwriting)
                    }
                }
                var p99 = -1, maximum = -1
                if a.width == b.width && a.height == b.height {
                    var histogram = [Int](repeating: 0, count: 256)
                    a.data.withUnsafeBytes { ap in b.data.withUnsafeBytes { bp in
                        for index in 0..<min(ap.count, bp.count) { histogram[abs(Int(ap[index]) - Int(bp[index]))] += 1 }
                    } }
                    let total = histogram.reduce(0, +), threshold = Int(ceil(Double(total) * 0.99))
                    var count = 0
                    p99 = 0
                    for (error, frequency) in histogram.enumerated() {
                        count += frequency
                        if count >= threshold { p99 = error; break }
                    }
                    maximum = histogram.lastIndex(where: { $0 > 0 }) ?? 0
                }
                let payload = try XCTUnwrap(recipe.adjustmentsV3)
                let effectiveDecoder = DevelopmentRAWSourcePolicy.usesFlashRaw(payload)
                    ? DevelopmentRAWDecoder.flashRaw031.rawValue : "CIRAW/" + session.decoderVersion
                // Opt-in: the native 1:1 frame for the same recipe, to size the remaining
                // full-resolution cost that `detail` still pays.
                var detailMilliseconds: Double?
                if environment["RAWMASTER_INTERACTIVE_DETAIL"] == "1" {
                    revision += 1
                    // RAWMASTER_INTERACTIVE_DETAIL_WINDOW=1 scopes the 1:1 frame to the pixels a
                    // 2400x1600 canvas would show, centred away from the origin.
                    // `1` is a tight viewport window; `margin` is the 50%-per-side window the
                    // canvas asks for, which is what ships.
                    let windowMode = environment["RAWMASTER_INTERACTIVE_DETAIL_WINDOW"]
                    let detailWindow: CGRect?
                    switch windowMode {
                    case "1": detailWindow = CGRect(x: 0.37, y: 0.31, width: 0.2525, height: 0.2525)
                    case "margin": detailWindow = CGRect(x: 0.2475, y: 0.1875, width: 0.505, height: 0.505)
                    default: detailWindow = nil
                    }
                    let detailSamples = Int(environment["RAWMASTER_INTERACTIVE_DETAIL_SAMPLES"] ?? "1") ?? 1
                    var detailTimes: [Double] = []
                    var detail: DevelopmentPreviewFrame?
                    for _ in 0..<max(1, detailSamples) {
                        revision += 1
                        let detailStarted = DispatchTime.now().uptimeNanoseconds
                        detail = try await service.render(.init(sessionID: session.id, sourceGeneration: session.sourceGeneration,
                            consumerID: consumer, role: .primary, revision: revision, recipe: recipe,
                            quality: .detail, viewport: .init(maxPixel: 0, window: detailWindow)))
                        detailTimes.append(Double(DispatchTime.now().uptimeNanoseconds - detailStarted) / 1_000_000)
                    }
                    detailMilliseconds = detailTimes.first
                    if detailTimes.count > 1 {
                        print("DETAIL-SAMPLES \(label) \(detailTimes.map { String(format: "%.1f", $0) }.joined(separator: ","))")
                    }
                    let detailFrame = try XCTUnwrap(detail)
                    XCTAssertNil(detailFrame.approximation, "detail must stay native: \(label)")
                    XCTAssertEqual(detailFrame.window, detailWindow)
                    if let detailWindow {
                        let expected = try V3PreviewMaterializer.visibleRect(
                            detailWindow, of: CGRect(origin: .zero, size: detailFrame.canonicalPixelSize))
                        XCTAssertEqual(detailFrame.outputPixelSize, expected.size, "windowed size for \(label)")
                    } else {
                        XCTAssertEqual(detailFrame.outputPixelSize, detailFrame.canonicalPixelSize)
                    }
                    print("DETAIL-FRAME \(label) \(detailMilliseconds ?? 0) out=\(Int(detailFrame.outputPixelSize.width))x\(Int(detailFrame.outputPixelSize.height)) canvas=\(Int(detailFrame.canonicalPixelSize.width))x\(Int(detailFrame.canonicalPixelSize.height))")
                    if environment["RAWMASTER_INTERACTIVE_WRITE_IMAGES"] == "1" {
                        guard let cg = detailFrame.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                              let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
                        else { throw DevelopmentError.unreadable }
                        try data.write(to: output.appendingPathComponent("\(label)-detail.png"), options: .withoutOverwriting)
                    }
                }
                measurements.append(.init(label: label, effectiveDecoder: effectiveDecoder, interactiveMilliseconds: interactiveTimes,
                    interactiveMedianMilliseconds: median(interactiveTimes), settledMilliseconds: settledTime,
                    approximate: interactiveFrame.approximate, width: a.width, height: a.height,
                    settledWidth:Int(published.outputPixelSize.width),settledHeight:Int(published.outputPixelSize.height),
                    qualityComparison:reference.outputPixelSize == referenceSize ? "matched-pixels" : "settled-resampled-to-proxy",
                    p99ChannelError: p99, maximumChannelError: maximum, detailMilliseconds: detailMilliseconds))
            }
            await service.closeAll()
            await referenceService?.closeAll()
        } catch {
            await service.closeAll()
            throw error
        }
        let telemetry = ImagePerformanceTelemetry.shared.snapshot()
        let engineStages = telemetry.recent.map { sample in
            ["operation":sample.operation,"stage":sample.stage,"boundary":sample.boundary.rawValue,
             "outcome":sample.outcome.rawValue,"durationMilliseconds":sample.durationMilliseconds,
             "pixelCount":sample.pixelCount] as [String:Any]
        }
        let decoderStages = try JSONSerialization.jsonObject(with: JSONEncoder().encode(telemetry.recent.compactMap(\.flashRaw)))
        let latestDecode = try JSONSerialization.jsonObject(with:JSONEncoder().encode(telemetry.latestFlashRaw),options:.fragmentsAllowed)
        let cacheStats = FlashRawCanonicalTexturePool.shared.statistics()
        let sourceSHA256After = try RenderFiles.hash(sourceURL)
        let report: [String: Any] = [
            "schemaVersion":1,
            "build":"release",
            "binarySHA256":try RenderFiles.hash(XCTUnwrap(Bundle(for:Self.self).executableURL)),
            "recordedAt":ISO8601DateFormatter().string(from:Date()),
            "sourceSHA256": source.contentSHA256,
            "sourceSHA256After":sourceSHA256After,
            "transparentFrameFailures":transparentFrameFailures,
            "flashRawTextureCache":["hits":cacheStats.hits,"fills":cacheStats.fills,"residentBytes":cacheStats.residentBytes,"pinnedBytes":cacheStats.pinnedBytes,"peakReservedBytes":cacheStats.peakReservedBytes,"bytesPerPixel":8,"guideBytesPerPixel":4],
            "prewarming":prewarming,
            "flashRawAvailable":flashRawAvailable,
            "flashRawDemosaic": storedDecoder == nil ? FlashRawDemosaic.measurementOverride.rawValue : FlashRawDemosaic.bilinear.rawValue,
            "canonicalFlashRaw": DevelopmentRAWSourcePolicy.usesFlashRaw(neutral),
            "sourceDecoder":storedDecoder?.rawValue ?? "CIRAW/" + session.decoderVersion,
            "decoderOverride":environment["RAWMASTER_CANONICAL_FLASHRAW"] == "1",
            "rawBaseCacheBytes":rawBaseCacheBytes,
            "engineStages":engineStages,
            "flashRawDecodeStatistics":decoderStages,
            "latestFlashRawDecode":latestDecode,
            "decoderVersion": session.decoderVersion,
            "proxyVersion": PreviewInteractiveProxyV3.version,
            "sourceOverlayVersion": PreviewInteractiveProxyV3.sourceOverlayVersion,
            "policy": "proxyV1 interactive; \(settledTransport.rawValue) settled; bitmapCache=\(bitmapCacheBytes); rawBaseCache=\(rawBaseCacheBytes)",
            "settledTransport": settledTransport.rawValue,
            "settledReferenceTransport": referenceService == nil ? settledTransport.rawValue : PreviewSettledTransport.canonical.rawValue,
            "measurements": try JSONSerialization.jsonObject(with: JSONEncoder().encode(measurements)),
            "caveats": [
                "API return timing only; no WindowServer presentation or Adobe Camera Raw timing",
                "Interactive and settled are bounded to the 2400px canvas; detail/save/export remain native",
                "Channel error is the settled frame against the native settled render, not against the gesture frame",
                "Cold process and OS caches are not purged; three consecutive samples per operation"
            ]
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .withoutOverwriting)
        print("INTERACTIVE-PERFORMANCE \(measurements.map { [$0.label, $0.interactiveMedianMilliseconds, $0.settledMilliseconds, $0.p99ChannelError] })")
    }
}
