import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMaster

/// Opt-in real RAW controller + native AppKit canvas timing. The draw event carries the actual return time.
final class EditingInteractionPerformanceTests: XCTestCase {
    struct ProbeFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
        init(_ message: String) { self.message = message }
    }

    static func required<T>(_ value: T?, _ message: String = "Required probe value is absent",
                            file: StaticString = #fileID, line: UInt = #line) throws -> T {
        guard let value else { throw ProbeFailure("\(file):\(line) \(message)") }
        return value
    }

    static func gate(_ condition: Bool, _ name: String, _ report: inout [String: Any]) {
        var gates = report["gates"] as? [String: Bool] ?? [:]
        gates[name] = condition && (gates[name] ?? true)
        report["gates"] = gates
    }

    @MainActor func wait(_ label: String, seconds: Double = 30, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw ProbeFailure("Timed out: " + label)
    }

    func statistics(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        let median = sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        return ["count": sorted.count, "medianMs": median,
            "p95Ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
            "maxMs": sorted[sorted.count - 1], "samplesMs": values]
    }

    struct Draw {
        let event: ImageFrameDrawEvent
        let revision, generation: UInt64
        let leaseID, consumerID: UUID
        let quality: String
        let approximate: Bool
        let renderedSize: CGSize
        func duration(since start: UInt64) throws -> Double {
            guard event.drawReturnedUptimeNanoseconds >= start else { throw ProbeFailure("Draw predates input") }
            return Double(event.drawReturnedUptimeNanoseconds - start) / 1_000_000
        }
        func evidence(start: UInt64) -> [String: Any] {
            ["inputNS":start, "drawBeganNS":event.drawBeganUptimeNanoseconds, "drawReturnedNS":event.drawReturnedUptimeNanoseconds,
             "frameID":event.frameID.uuidString, "revision":revision, "generation":generation, "quality":quality,
             "leaseID":leaseID.uuidString, "consumerID":consumerID.uuidString,
             "approximate":approximate, "width":event.imagePixelWidth, "height":event.imagePixelHeight,
             "renderedWidth":Int(renderedSize.width), "renderedHeight":Int(renderedSize.height)]
        }
    }

    @MainActor func drawn(_ editing: EditingController, recipe: DevelopmentRecipe, quality: PreviewQuality,
                          after start: UInt64 = 0, label: String, seconds: Double = 90) async throws -> Draw {
        let pane = editing.previews.primary
        var accepted: Draw?
        try await wait(label, seconds: seconds) {
            if pane.error != nil && !pane.rendering { return true }
            guard pane.frameRecipe == recipe, let frame = pane.frame, frame.quality == quality,
                  let event = pane.currentAcceptedDraw, event.frameID == frame.id,
                  event.drawReturnedUptimeNanoseconds >= start else { return false }
            accepted = Draw(event: event, revision: frame.revision, generation: frame.generation,
                            leaseID:frame.leaseID.rawValue, consumerID:frame.consumerID.rawValue,
                            quality: frame.quality.rawValue, approximate: frame.approximate, renderedSize:frame.outputSize)
            return true
        }
        if accepted == nil, let failure = pane.error {
            throw ProbeFailure("\(label): \(failure), rendering=\(pane.rendering), quality=\(pane.frame?.quality.rawValue ?? "none"), recipeMatched=\(pane.frameRecipe == recipe)")
        }
        let draw = try Self.required(accepted)
        guard draw.renderedSize == CGSize(width:draw.event.imagePixelWidth,height:draw.event.imagePixelHeight),
              quality == .detail || max(draw.renderedSize.width,draw.renderedSize.height) <= 2400 else {
            throw ProbeFailure("\(label) raster \(draw.renderedSize) differs from drawn \(draw.event.imagePixelWidth)×\(draw.event.imagePixelHeight) or exceeds the 2400-pixel preview")
        }
        return draw
    }

    static func counters() async -> [String: Any] {
        let stats = await ImageEngines.previewLifecycle.statistics()
        let monitoring = await ImageEngines.monitoring.performanceSnapshot()
        let texture = FlashRawCanonicalTexturePool.shared.statistics()
        let decodes = monitoring.aggregates.filter { $0.boundary == .decode }
        let flashRawDecodes = decodes.filter { $0.operation == "FlashRaw.decode" }.reduce(into: [String:Int]()) {
            $0[$1.stage, default:0] += $1.sampleCount
        }
        return ["submitted":stats.submittedRequests, "completed":stats.completedRenders, "superseded":stats.supersededRequests,
                "bitmapCacheHits":stats.cacheHits, "sourceCaptures":stats.sourceCaptures, "sourceHashPasses":stats.sourceFullHashPasses,
                "rawBaseFills":stats.rawBaseFills, "rawBaseHits":stats.rawBaseHits, "rawBaseMisses":stats.rawBaseMisses,
                "canonicalTextureFills":texture.fills, "canonicalTextureHits":texture.hits, "canonicalTextureBytes":texture.residentBytes,
                "fallbacks":stats.interactiveProxyCanonicalFallbacks, "lastFallback":stats.interactiveProxyLastFallbackReason ?? "",
                "nativeInteractiveJobs":stats.nativeProfileInteractiveJobs, "nativeCanonicalJobs":stats.nativeProfileCanonicalJobs,
                "nativeLastRoute":stats.nativeProfileLastRoute, "flashRawLatestDecodeBackend":monitoring.latestFlashRaw?.decoderBackend ?? "",
                "flashRawDecodesByStage":flashRawDecodes,
                "decodeOperations":decodes.map { ["operation":$0.operation,"stage":$0.stage,"count":$0.sampleCount] as [String:Any] }]
    }

    static func previewDelta(_ old: PreviewStatistics, _ new: PreviewStatistics) -> [String: Any] {
        ["submitted":new.submittedRequests - old.submittedRequests, "renders":new.completedRenders - old.completedRenders,
         "bitmapHits":new.cacheHits - old.cacheHits, "rawBaseFills":new.rawBaseFills - old.rawBaseFills,
         "rawBaseHits":new.rawBaseHits - old.rawBaseHits, "fallbacks":new.interactiveProxyCanonicalFallbacks - old.interactiveProxyCanonicalFallbacks,
         "lastNativeRoute":new.nativeProfileLastRoute, "lastFallback":new.interactiveProxyLastFallbackReason ?? ""]
    }

    @MainActor private func comparePresetWithManualExposure(editing: EditingController, context: EditingInteractionContext,
                                                             mirrored: Bool, diagnostic: Bool, report: inout [String: Any]) async throws {
        let session = editing.developmentSession
        let baseline = session.recipe
        let baselineFingerprint = try EditingFingerprint.of(baseline)
        var samples = ["preset": [Double](), "manual": [Double]()], draws: [[String: Any]] = []
        var exposureValues: [Double] = []
        var matchedPairs = 0
        var warmCounts = [String:[String:UInt64]]()
        let evenOrder = mirrored ? ["manual","preset"] : ["preset","manual"]
        defer {
            var result: [String: Any] = ["order":mirrored ? "alternating BA/AB" : "alternating AB/BA", "exposureValues":exposureValues, "draws":draws,
                "mirrored":mirrored, "evenPairOrder":evenOrder, "countsTowardAcceptance":!diagnostic,
                "matchedRecipeAndExposurePairs":matchedPairs, "warmObservedCounters":warmCounts,
                "baselineRecipeSHA256":baselineFingerprint, "firstPair":"warm-up",
                "boundary":"discrete edit to accepted settled AppKit canvas draw return"]
            for path in ["preset", "manual"] {
                let series = samples[path] ?? []
                result[path] = ["firstMs":series.first.map { $0 as Any } ?? NSNull(), "warm":statistics(Array(series.dropFirst()))]
            }
            let preset = statistics(Array((samples["preset"] ?? []).dropFirst()))["p95Ms"] as? Double
            let manual = statistics(Array((samples["manual"] ?? []).dropFirst()))["p95Ms"] as? Double
            let complete = samples["preset"]?.count == 31 && samples["manual"]?.count == 31 && matchedPairs == 31
            let passes = complete && (preset ?? .infinity) <= (manual ?? -.infinity)
            result["meetsReferenceP95Comparison"] = passes
            if diagnostic {
                let prefix = mirrored ? "paired.mirror" : "paired.trace"
                Self.gate(complete, prefix + ".completeMatchedExposurePairs", &report)
                let accounted = ["preset","manual"].allSatisfy { path in
                    guard let counts = warmCounts[path], let hits = counts["bitmapHits"], let renders = counts["renders"] else { return false }
                    return counts["submitted"] == 30 && hits + renders == 30
                }
                Self.gate(accounted, prefix + ".completeWarmFrameCounters", &report)
            } else {
                result["passes"] = passes
                Self.gate(passes, "paired.30Warm.presetP95AtMostManualP95", &report)
            }
            report["pairedExposure"] = result
        }
        for pair in 0...30 {
            let target = 0.12 + Double(pair) * 0.005
            exposureValues.append(target)
            var patch = DevelopmentPresetPatch(); patch.exposure = target
            let preset = DevelopmentPresetRecord(id: "qa-exposure", name: "曝光", group: "QA", kind: .user, patch: patch)
            var firstRecipe: DevelopmentRecipe?
            var firstFingerprint: String?
            let order = pair.isMultiple(of:2) ? evenOrder : Array(evenOrder.reversed())
            for (position,path) in order.enumerated() {
                guard session.recipe == baseline else { throw ProbeFailure("Paired baseline recipe changed") }
                let baselineDraw = try await drawn(editing, recipe: baseline, quality: .settled, label: "matched baseline for " + path)
                let before = await ImageEngines.previewLifecycle.statistics()
                let started = DispatchTime.now().uptimeNanoseconds
                if path == "preset" { try session.adoptPreset(preset, context: context, revision: session.revision) }
                else {
                    var light = session.parameters.light; light.enabled = true; light.exposure = target
                    try session.apply(.setParameters(.light(light)), event: .init(context: context,
                        control: .init(group: .light, name: "曝光"),
                        nativeInput: .capture(control: "light.exposure", phase: "discrete", nativeEvent: true)))
                }
                let committed = DispatchTime.now().uptimeNanoseconds
                let settled = try await drawn(editing, recipe: session.recipe, quality: .settled, after: started,
                                              label: "settled draw for " + path)
                samples[path, default: []].append(try settled.duration(since: started))
                var row = settled.evidence(start: started)
                row["committedNS"] = committed
                row["synchronousCommandMs"] = Double(committed - started) / 1_000_000
                row["pair"] = pair; row["path"] = path; row["baselineFrameID"] = baselineDraw.event.frameID.uuidString
                row["positionInPair"] = position + 1
                row["targetNativeExposure"] = target
                let actual = try Self.required(session.recipe.adjustmentsV3?.light.exposure)
                row["resultNativeExposure"] = actual
                row["baselineDrawNS"] = baselineDraw.event.drawReturnedUptimeNanoseconds
                let hash = try EditingFingerprint.of(session.recipe)
                row["resultRecipeSHA256"] = hash
                let after = await ImageEngines.previewLifecycle.statistics()
                row["previewCounters"] = Self.previewDelta(before,after)
                draws.append(row)
                if pair > 0 {
                    warmCounts[path,default:[:]]["renders",default:0] += after.completedRenders - before.completedRenders
                    warmCounts[path,default:[:]]["bitmapHits",default:0] += after.cacheHits - before.cacheHits
                    warmCounts[path,default:[:]]["submitted",default:0] += after.submittedRequests - before.submittedRequests
                    warmCounts[path,default:[:]]["fallbacks",default:0] += after.interactiveProxyCanonicalFallbacks - before.interactiveProxyCanonicalFallbacks
                }
                guard actual == target else { throw ProbeFailure("Wrong native exposure at pair \(pair)") }
                if let firstRecipe {
                    guard firstRecipe == session.recipe, firstFingerprint == hash else { throw ProbeFailure("Paired recipes differ at pair \(pair)") }
                    matchedPairs += 1
                } else {
                    firstRecipe = session.recipe
                    firstFingerprint = hash
                }
                try session.undo(context: context)
            }
        }
        _ = try await drawn(editing, recipe: baseline, quality: .settled, label: "last paired undo")
    }

    @MainActor func testOptInRealRAWCompoundEditingCanvasPerformance() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["RAWMASTER_EDITING_PERF"] == "1" else { throw XCTSkip("Real RAW window measurement is opt-in") }
        defer { if InteractionTrace.shared.isEnabled { InteractionTrace.shared.flush() } }
        guard let path = env["RAWMASTER_EDITING_PERF_OUTPUT"], !path.isEmpty else { throw ProbeFailure("Set a fresh RAWMASTER_EDITING_PERF_OUTPUT to save evidence") }
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let destination = output.appendingPathComponent("editing-interaction-performance.json")
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        var report: [String: Any] = ["status":"running", "build":"release", "gates":[String:Bool](),
            "measurementBoundary":"programmatic recipe commit to accepted AppKit canvas draw return; not physical input or WindowServer presentation",
            "engine":String(reflecting: type(of: ImageEngines.editing)), "composition":"AppModel.editing / ImageEngines.editing",
            "clock":"DispatchTime.uptimeNanoseconds, frame-correlated drawReturnedUptimeNanoseconds"]
        func writeReport() throws {
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]).write(to: destination, options: .withoutOverwriting)
        }
        #if DEBUG
        report["status"] = "skipped"; report["build"] = "debug"; report["failure"] = "Release measurements required"
        try writeReport()
        throw XCTSkip("Release measurements required")
        #else
        let workerPhasesRequested = env["RAWMASTER_QA_VIEWPORT_WORKER_PHASES"] == "1"
        if workerPhasesRequested { report["workerPhasesRequested"] = true }
        do {
            try await runWindow(environment: env, output: output, report: &report)
            if workerPhasesRequested {
                guard report["pairedDiagnostic"] as? Bool == true,
                      let capture = PreviewQALifecycleTrace.viewportCaptureForTesting(), !capture.phases.isEmpty else {
                    throw ProbeFailure("Worker phases require the paired diagnostic window and an absolute interaction trace")
                }
                let workerTrace = output.appendingPathComponent("worker-phases.json")
                try JSONEncoder().encode(capture).write(to: workerTrace, options: .withoutOverwriting)
                guard !capture.overflow else { throw ProbeFailure("Worker phase trace capacity exceeded") }
            }
            let gates = report["gates"] as? [String:Bool] ?? [:]
            let failures = gates.filter { !$0.value }.keys.sorted()
            guard !gates.isEmpty, failures.isEmpty else { throw ProbeFailure("Failed acceptance gates: " + failures.joined(separator: ", ")) }
            if report["pairedDiagnostic"] as? Bool == true {
                report["status"] = "diagnostic-complete"
            } else {
                report["status"] = "passed"; report["passes"] = true
            }
        } catch {
            report["status"] = "failed"; report["passes"] = false; report["failure"] = error.localizedDescription
            try writeReport()
            throw error
        }
        try writeReport()
        print("EDITING-CANVAS-PERFORMANCE \(destination.path)")
        #endif
    }

    @MainActor private func runWindow(environment: [String:String], output: URL, report: inout [String:Any]) async throws {
        let sourcePath = try Self.required(environment["RAWMASTER_EDITING_PERF_SOURCE"], "Missing explicit RAW")
        let lightflowPath = try Self.required(environment["RAWMASTER_LIGHTFLOW_REFERENCE"], "Missing Lightflow reference")
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        let run = output.appendingPathComponent("fixture", isDirectory: true)
        guard ![run,output.appending(path:"reopened-subject.tiff"),output.appending(path:"disabled-layer-control.tiff"),
                output.appending(path:"same-renderer-zero-coverage.tiff")].contains(where: { FileManager.default.fileExists(atPath:$0.path) }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
        let library = run.appendingPathComponent("fixture.sqlite")
        let prepared = try await Task.detached { () -> (LibraryStore, AssetRecord, String) in
            let store = try LibraryStore(databaseURL: library)
            let project = ProjectRecord(name: "Real editing canvas performance")
            try store.saveProject(project)
            let session = ImportSession(projectID: project.id, projectName: project.name, sourcePath: source.deletingLastPathComponent().path,
                mode: .reference, status: "completed", discovered: 1, completed: 1, scanCompleted: true)
            try store.saveSession(session)
            let hash = try FileSafety.hash(source), bytes = try FileSafety.stat(source).size
            var width: Int?, height: Int?
            if let image = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
               let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any] {
                width = properties[kCGImagePropertyPixelWidth as String] as? Int
                height = properties[kCGImagePropertyPixelHeight as String] as? Int
            }
            let asset = try store.register(.init(sessionID: session.id, projectID: project.id, projectName: project.name,
                sourcePath: source.path, currentPath: source.path, filename: source.lastPathComponent, fileSize: bytes,
                width: width, height: height, contentHash: hash, importState: .ready))
            try store.completedDirectImport(session)
            return (store, asset, hash)
        }.value

        let asset = prepared.1
        let defaults = try Self.required(UserDefaults(suiteName: "EditingPerformance-" + UUID().uuidString))
        let filterOnly = environment["RAWMASTER_EDITING_PERF_FILTER_ONLY"] == "1"
        let pairedPreset = environment["RAWMASTER_EDITING_PERF_PRESET_PAIR"] == "1"
        let mirrored = environment["RAWMASTER_EDITING_PERF_PRESET_MIRROR"] == "1"
        let pairedDiagnostic = pairedPreset && (mirrored || InteractionTrace.shared.isEnabled)
        let measureMask = environment["RAWMASTER_EDITING_PERF_MASK_SUBJECT"] == "1"
        guard [filterOnly,pairedPreset,measureMask].filter({ $0 }).count <= 1 else { throw ProbeFailure("Conflicting measurement selections") }
        guard !mirrored || pairedPreset else { throw ProbeFailure("Mirrored diagnostics require RAWMASTER_EDITING_PERF_PRESET_PAIR=1") }
        let burst = environment["RAWMASTER_EDITING_PERF_INTERACTIVE_BURST"] == "1"
        report["sourceSHA256"] = prepared.2; report["sourcePixelWidth"] = asset.width ?? 0; report["sourcePixelHeight"] = asset.height ?? 0
        report["lightflowReference"] = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: lightflowPath)))
        report["filterOnly"] = filterOnly
        report["protocol"] = filterOnly ? "filter-canvas-burst-v1" : (burst ? "interactive-burst-one-settled-per-case-v1" : "settled-every-gesture-v1")
        if pairedPreset {
            if mirrored { report["protocol"] = "031-discrete-preset-manual-settled-mirror-diagnostic-v1" }
            else if pairedDiagnostic { report["protocol"] = "031-discrete-preset-manual-settled-trace-diagnostic-v1" }
            else { report["protocol"] = "031-discrete-preset-manual-settled-v1" }
            report["pairedDiagnostic"] = pairedDiagnostic
            report["mirroredPresetDiagnostic"] = mirrored
            report["interactionTraceEnabled"] = InteractionTrace.shared.isEnabled
        }
        if measureMask { report["protocol"] = "027-editor-subject-and-frozen-export-v1" }
        report["engineBeforeApp"] = await Self.counters()
        let appModel = AppModel(libraryURL: library, defaults: defaults)
        let editing = try Self.required(appModel.editing, appModel.errorMessage ?? "AppModel failed to construct its production editor")
        let host = NSHostingView(rootView: EditingImageCanvas(editing: editing).environmentObject(appModel))
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        var didClose = false
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await wait("initial real RAW frame", seconds:90) { editing.work != nil && editing.previews.primary.frame != nil }
            editing.beginDevelopmentInterface()
            try await wait("active editing session") { editing.developmentContext != nil }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let context = try Self.required(editing.developmentContext)
            let initial = try await drawn(editing, recipe: editing.recipe, quality: .settled, label: "initial settled draw")
            report["initialFrame"] = initial.evidence(start: initial.event.drawBeganUptimeNanoseconds)
            report["recipeRawDecoder"] = editing.developmentSession.parameters.rawDecoder?.rawValue ?? "core-image"
            report["window"] = ["width":host.bounds.width,"height":host.bounds.height,"backingScale":window.backingScaleFactor]
            report["engineAfterInitialSettled"] = await Self.counters()

            let standardCases: [(String, Int, (Double) -> [DevelopmentAdjustmentCommand])] = [
                ("exposure", 8, { value in
                    var p = DevelopmentLightV3(); p.enabled = true; p.exposure = value
                    return [.setParameters(.light(p))]
                }),
                ("color", 8, { value in
                    var p = DevelopmentColorV3(); p.enabled = true; p.vibrance = value; p.saturation = value / 2
                    return [.setParameters(.color(p))]
                }),
                ("texture", 6, { value in
                    var p = DevelopmentAdvancedDetailV3(); p.texture = .init(enabled: true, amount: value)
                    return [.setParameters(.texture(p.texture))]
                }),
                ("clarity", 6, { value in
                    var p = DevelopmentAdvancedDetailV3(); p.clarity = .init(enabled: true, amount: value)
                    return [.setParameters(.clarity(p.clarity))]
                }),
                ("compound", 8, { value in
                    var light = DevelopmentLightV3(); light.enabled = true; light.exposure = value / 100
                    light.contrast = value / 200
                    var color = DevelopmentColorV3(); color.enabled = true; color.vibrance = value / 150
                    var detail = DevelopmentAdvancedDetailV3(); detail.texture = .init(enabled: true, amount: value / 2)
                    return [.setParameters(.light(light)), .setParameters(.color(color)), .setParameters(.texture(detail.texture))]
                })
            ]
            let filterCases: [(String, Int, (Double) -> [DevelopmentAdjustmentCommand])] = [
                ("filterLook", 8, { value in
                    let look = DevelopmentThumbnailEngine.filterOrder[Int(value / 5)]
                    return [.setParameters(.filter(.init(enabled: look != .original, selection: look, intensity: 50)))]
                }),
                ("filterIntensity", 8, { value in
                    [.setParameters(.filter(.init(enabled: true, selection: .vivid, intensity: value)))]
                }),
                ("filterCompound", 6, { value in
                    var light = DevelopmentLightV3(); light.enabled = true; light.exposure = 0.1
                    var color = DevelopmentColorV3(); color.enabled = true; color.saturation = 0.2
                    var detail = DevelopmentAdvancedDetailV3(); detail.texture = .init(enabled: true, amount: value)
                    return [.setParameters(.light(light)), .setParameters(.color(color)),
                        .setParameters(.texture(detail.texture)),
                        .setParameters(.filter(.init(enabled: true, selection: .vivid, intensity: 50)))]
                })
            ]

            var adoptedMask: DevelopmentMaskLayerV3?
            if pairedPreset { try await comparePresetWithManualExposure(editing: editing, context: context, mirrored:mirrored, diagnostic:pairedDiagnostic, report: &report) }
            if measureMask {
                report["measurementBoundary"] = "mask request to published adoptable candidate; adoption to accepted settled AppKit draw return; export to TIFF writer return"
                adoptedMask = try await measureSubjectMask(editing: editing, context: context, report: &report)
            }
            let cases = pairedPreset || measureMask ? [] : (filterOnly ? filterCases : standardCases)
            var allInteractive: [Double] = [], coldInteractive: [Double] = [], warmInteractive: [Double] = []
            for (label, count, makeCommands) in cases {
                var interactive: [Double] = [], settled: [Double] = [], evidence: [[String:Any]] = []
                let before = await Self.counters()
                var afterFirst: [String:Any]?, afterLast: [String:Any]?
                defer {
                    var row: [String:Any] = ["interactive":statistics(interactive), "settledAfterGesture":statistics(settled),
                                             "draws":evidence, "engineBefore":before]
                    row["engineAfterFirstSample"] = afterFirst
                    row["engineAfterLastSample"] = afterLast
                    report[label] = row
                }
                for index in 1...count {
                    let step: Double = switch label {
                    case "exposure": 0.05
                    case "color": 0.025
                    case "filterIntensity": 12
                    default: 5
                    }
                    let commands = makeCommands(Double(index) * step)
                    let token = try editing.developmentSession.beginGesture(.init(group: nil, name: label), context: context)
                    let started = DispatchTime.now().uptimeNanoseconds
                    try editing.developmentSession.applyAtomically(commands, title: label,
                        event: .init(context: context, control: .init(group: nil, name: label),
                            nativeInput: .capture(control: "performance." + label, phase: "change", nativeEvent: true, gestureID: token.id)), gesture: token)
                    let draw = try await drawn(editing, recipe: editing.recipe, quality: .interactive, after: started,
                                               label: label + " interactive draw \(index)")
                    interactive.append(try draw.duration(since: started)); evidence.append(draw.evidence(start:started))
                    let settling = DispatchTime.now().uptimeNanoseconds
                    try editing.developmentSession.endGesture(token, .commit)
                    if !filterOnly && (!burst || index == count) {
                        let final = try await drawn(editing, recipe: editing.recipe, quality: .settled, after: settling,
                                                    label: label + " settled draw \(index)")
                        settled.append(try final.duration(since: settling)); evidence.append(final.evidence(start:settling))
                    }
                    guard editing.developmentContext == context, editing.message == nil else { throw ProbeFailure("Editor changed context in " + label) }
                    if filterOnly && index == 1 { afterFirst = await Self.counters() }
                    if filterOnly && index == count { afterLast = await Self.counters() }
                }
                if filterOnly {
                    let first = try Self.required(afterFirst), last = try Self.required(afterLast)
                    for key in ["sourceCaptures","sourceHashPasses","fallbacks"] {
                        let initialCount = try Self.required(before[key] as? UInt64)
                        Self.gate(first[key] as? UInt64 == initialCount && last[key] as? UInt64 == initialCount,
                                  "classic." + label + ".stable." + key, &report)
                    }
                    let cold = try Self.required(first["flashRawDecodesByStage"] as? [String:Int])
                    let warm = try Self.required(last["flashRawDecodesByStage"] as? [String:Int])
                    Self.gate(!cold.isEmpty && cold == warm, "classic." + label + ".noWarmFlashRawDecode", &report)
                }
                allInteractive += interactive
                if let first = interactive.first { coldInteractive.append(first) }
                warmInteractive += interactive.dropFirst()
            }
            if !cases.isEmpty {
                report["allInteractive"] = statistics(allInteractive)
                report["coldInteractiveFirstPerCase"] = statistics(coldInteractive)
                let warm = statistics(warmInteractive)
                report["warmInteractiveAfterFirstPerCase"] = warm
                if filterOnly {
                    let p50 = try Self.required(warm["medianMs"] as? Double), p95 = try Self.required(warm["p95Ms"] as? Double)
                    report["classicThresholdsMs"] = ["warmP50Max":20,"warmP95Max":33]
                    Self.gate(warmInteractive.count == 19, "classic.19WarmHistoricalSamples", &report)
                    Self.gate(p50 <= 20, "classic.warmP50AtMost20ms", &report)
                    Self.gate(p95 <= 33, "classic.warmP95AtMost33ms", &report)
                }
            }
            let hashAfter = try await Task.detached { try FileSafety.hash(source) }.value
            report["sourceSHA256After"] = hashAfter
            Self.gate(hashAfter == prepared.2, "source.preserved", &report)
            report["engineAfterInteraction"] = await Self.counters()
            // An editor releases its leases. The shared engine lives until the application exits.
            await editing.shutdown()
            didClose = true
            if let adoptedMask {
                report["memoryAfterEditorShutdown"] = try Self.maskProcessMemory()
                let sourceID = try Self.required(adoptedMask.semanticSnapshot?.source.sourceContentID)
                let input = editing.developmentMaskInput
                let before = try Self.required(await input.analysisDiagnostics(for: sourceID), "Missing pre-export mask diagnostics")
                report["modelInvocationsBeforeReopen"] = before.modelInvocations
                let reopenStart = DispatchTime.now().uptimeNanoseconds
                let reopenedModel = AppModel(libraryURL: library, defaults: defaults)
                let reopened = try Self.required(reopenedModel.editing, "Failed to reopen normal editor")
                let reopenedInput = reopened.developmentMaskInput
                do {
                    let initialCalls = await reopenedInput.analysisDiagnostics(for: sourceID)?.modelInvocations ?? 0
                    let reopenedCanvas = NSHostingView(rootView: EditingImageCanvas(editing: reopened).environmentObject(reopenedModel))
                    window.contentView = reopenedCanvas
                    reopened.isPresented = true; reopened.focus(asset)
                    try await wait("reopened RAW editor", seconds:90) { reopened.work?.id == context.workID && reopened.previews.primary.frame != nil }
                    reopened.beginDevelopmentInterface()
                    try await wait("reopened edit context", seconds:90) { reopened.developmentContext != nil }
                    reopenedCanvas.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                    let frozen = try await drawn(reopened, recipe: reopened.recipe, quality: .settled, after: reopenStart, label: "reopened frozen mask draw")
                    report["reopenedDraw"] = frozen.evidence(start:reopenStart)
                    report["reopenedToFrozenSettledDrawMs"] = try frozen.duration(since:reopenStart)
                    Self.gate(reopened.recipe.adjustmentsV3?.masks.contains(adoptedMask) == true, "mask.freshEditorReopensAdoptedLayer", &report)
                    let reopenedCalls = await reopenedInput.analysisDiagnostics(for:sourceID)?.modelInvocations ?? 0
                    report["freshEditorInvocationsBeforeReopen"] = initialCalls
                    report["freshEditorInvocationsAtSettled"] = reopenedCalls
                    try await Self.exportReopenedMask(library: library, workID: context.workID, layer: adoptedMask,
                                                      output: output, report: &report)
                    let exportedCalls = await reopenedInput.analysisDiagnostics(for:sourceID)?.modelInvocations ?? 0
                    report["freshEditorInvocationsAfterExport"] = exportedCalls
                    Self.gate(initialCalls == 0 && reopenedCalls == 0 && exportedCalls == 0,
                              "mask.freshEditorReopenAndExportNoModelInvocations", &report)
                } catch {
                    await reopened.shutdown()
                    throw error
                }
                await reopened.shutdown()
                let after = try Self.required(await input.analysisDiagnostics(for: sourceID), "Missing post-export mask diagnostics")
                report["modelInvocationsAfterExport"] = after.modelInvocations
                Self.gate(before.modelInvocations == after.modelInvocations, "mask.reopenExportNoModelInvocations", &report)
                let control = try Self.required(report["togglePixelComparison"] as? [String:Int])
                Self.gate(control["protectedMaximumRGBA16Difference"] == 0, "mask.disabledToggleProtectedPixelsExact", &report)
                let finalHash = try await Task.detached { try FileSafety.hash(source) }.value
                report["sourceSHA256AfterExport"] = finalHash
                Self.gate(finalHash == prepared.2, "source.preservedAfterExport", &report)
            }
            await ImageEngines.previewLifecycle.closeAll()
            report["engineAfterReleaseAndExport"] = await Self.counters()
        } catch {
            report["engineAtFailure"] = await Self.counters()
            if !didClose { await editing.shutdown() }
            await ImageEngines.previewLifecycle.closeAll()
            throw error
        }
    }
}
