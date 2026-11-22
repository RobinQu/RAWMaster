import AppKit
import ImageIO
import SwiftUI
import XCTest
@testable import RAWMasterCore
@testable import RAWMasterImaging
@testable import RAWMaster

/// Opt-in real RAW controller + native AppKit canvas timing. Programmatic input is not physical input.
final class EditingInteractionPerformanceTests: XCTestCase {
    private enum Failure: Error { case timedOut(String), conflictingMeasurements }

    @MainActor func wait(_ label: String, seconds: Double = 30, _ condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTFail("Timed out: " + label)
        throw Failure.timedOut(label)
    }

    func statistics(_ values: [Double]) -> [String: Any] {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return [:] }
        let median = sorted.count % 2 == 0 ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
        return ["count": sorted.count, "medianMs": median,
            "p95Ms": sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)],
            "maxMs": sorted[sorted.count - 1], "samplesMs": values]
    }

    @MainActor private func comparePresetWithManualExposure(
        editing: EditingController, context: EditingInteractionContext
    ) async throws -> [String: Any] {
        let session = editing.developmentSession
        let baseline = session.recipe
        var samples = ["preset": [Double](), "manual": [Double]()]
        var exposureValues: [Double] = []
        for pair in 0...30 {
            let target = 0.12 + Double(pair) * 0.005
            exposureValues.append(target)
            var patch = DevelopmentPresetPatch()
            patch.exposure = target
            let preset = DevelopmentPresetRecord(id: "qa-exposure", name: "曝光", group: "QA", kind: .user, patch: patch)
            let order = pair.isMultiple(of: 2) ? ["preset", "manual"] : ["manual", "preset"]
            var firstRecipe: DevelopmentRecipe?
            for path in order {
                XCTAssertEqual(session.recipe, baseline)
                let started = DispatchTime.now().uptimeNanoseconds
                if path == "preset" {
                    try session.adoptPreset(preset, context: context, revision: session.revision)
                } else {
                    var light = session.parameters.light
                    light.enabled = true
                    light.exposure = target
                    try session.apply(.setParameters(.light(light)), event: .init(context: context,
                        control: .init(group: .light, name: "曝光"),
                        nativeInput: .capture(control: "light.exposure", phase: "discrete", nativeEvent: true)))
                }
                try await wait("settled draw for " + path, seconds: 60) {
                    editing.previews.primary.frameRecipe == session.recipe &&
                        editing.previews.primary.frame?.quality == .settled && editing.previews.primary.currentFrameWasDrawn
                }
                samples[path, default: []].append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                if let firstRecipe { XCTAssertEqual(session.recipe, firstRecipe) } else { firstRecipe = session.recipe }
                try session.undo(context: context)
                try await wait("restore matched baseline", seconds: 60) {
                    session.recipe == baseline && editing.previews.primary.frameRecipe == baseline &&
                        editing.previews.primary.frame?.quality == .settled && editing.previews.primary.currentFrameWasDrawn
                }
            }
        }
        var result: [String: Any] = ["order": "alternating AB/BA", "exposureValues": exposureValues,
            "boundary": "discrete edit to accepted settled canvas draw return", "firstPair": "warm-up"]
        var p95: [String: Double] = [:]
        for path in ["preset", "manual"] {
            let series = try XCTUnwrap(samples[path])
            let warm = statistics(Array(series.dropFirst()))
            result[path] = ["firstMs": try XCTUnwrap(series.first), "warm": warm] as [String: Any]
            p95[path] = try XCTUnwrap(warm["p95Ms"] as? Double)
        }
        let presetP95 = try XCTUnwrap(p95["preset"])
        let manualP95 = try XCTUnwrap(p95["manual"])
        result["passes"] = presetP95 <= manualP95
        XCTAssertLessThanOrEqual(presetP95, manualP95, "031 SC-02 same-source discrete exposure")
        return result
    }

    @MainActor func testOptInRealRAWCompoundEditingCanvasPerformance() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["RAWMASTER_EDITING_PERF"] == "1",
              let sourcePath = environment["RAWMASTER_EDITING_PERF_SOURCE"],
              let outputPath = environment["RAWMASTER_EDITING_PERF_OUTPUT"],
              let lightflowPath = environment["RAWMASTER_LIGHTFLOW_REFERENCE"] else {
            throw XCTSkip("Explicit RAW, new output and Lightflow reference are required")
        }
        #if DEBUG
        throw XCTSkip("Release measurements required")
        #endif
        _ = NSApplication.shared
        let source = URL(fileURLWithPath: sourcePath).resolvingSymlinksInPath()
        let output = URL(fileURLWithPath: outputPath, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let reportURL = output.appendingPathComponent("editing-interaction-performance.json")
        let run = output.appendingPathComponent("fixture", isDirectory: true)
        let ownedURLs = [reportURL, run, output.appending(path: "reopened-subject.tiff"), output.appending(path: "disabled-layer-control.tiff"),
                         output.appending(path: "same-renderer-zero-coverage.tiff")]
        guard !ownedURLs.contains(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
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
            return (store, asset, hash)
        }.value
        let store = prepared.0, asset = prepared.1
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EditingPerformance-" + UUID().uuidString))
        let filterOnly = environment["RAWMASTER_EDITING_PERF_FILTER_ONLY"] == "1"
        let pairedPreset = environment["RAWMASTER_EDITING_PERF_PRESET_PAIR"] == "1"
        let measureMask = environment["RAWMASTER_EDITING_PERF_MASK_SUBJECT"] == "1"
        if measureMask && (filterOnly || pairedPreset) {
            throw Failure.conflictingMeasurements
        }
        let service = DevelopmentPreviewService(policy: .init(bitmapCacheBytes: 0,
            rawBaseCacheBytes: filterOnly || pairedPreset || measureMask ? 1_073_741_824 : 0, interactiveEvaluation: .proxyV1))
        let backend = SharedEditingPreviewBackend(service: service)
        let editing = try EditingController(store: store, libraryURL: library, defaults: defaults, previewBackend: backend)
        let appModel = AppModel(libraryURL: library, defaults: defaults)
        let host = NSHostingView(rootView: EditingImageCanvas(editing: editing).environmentObject(appModel))
        let window = NSWindow(contentRect: .init(x: 40, y: 40, width: 1100, height: 760),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        let interactiveBurst = environment["RAWMASTER_EDITING_PERF_INTERACTIVE_BURST"] == "1"
        var report: [String: Any] = [
            "build": "release", "sourceSHA256": prepared.2,
            "protocol": filterOnly ? "filter-canvas-burst-v1" : (interactiveBurst ? "interactive-burst-one-settled-per-case-v1" : "settled-every-gesture-v1"),
            "filterOnly": filterOnly,
            "sourcePixelWidth": asset.width ?? 0, "sourcePixelHeight": asset.height ?? 0,
            "measurementBoundary": "programmatic recipe commit to accepted AppKit canvas draw return; not physical input or WindowServer presentation",
            "lightflowReference": try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: lightflowPath)))
        ]
        var editorDidClose = false
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await wait("initial real RAW frame") { editing.work != nil && editing.previews.primary.frame != nil }
            editing.beginDevelopmentInterface()
            try await wait("active editing session") { editing.developmentContext != nil }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await wait("initial canvas draw") { editing.previews.primary.currentFrameWasDrawn }
            let context = try XCTUnwrap(editing.developmentContext)
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
            if pairedPreset {
                report["protocol"] = "031-discrete-preset-manual-settled-v1"
                report["pairedExposure"] = try await comparePresetWithManualExposure(editing: editing, context: context)
            }
            var adoptedMask: DevelopmentMaskLayerV3?
            if measureMask {
                report["protocol"] = "027-editor-subject-and-frozen-export-v1"
                report["measurementBoundary"] = "Mask request to a candidate ready for review. Adoption to settled AppKit draw return. Reopened recipe to TIFF writer return."
                try await wait("initial settled draw before subject request", seconds: 90) {
                    editing.previews.primary.frameRecipe == editing.recipe &&
                        editing.previews.primary.frame?.quality == .settled && editing.previews.primary.currentFrameWasDrawn
                }
                let before = await service.statistics()
                adoptedMask = try await measureSubjectMask(editing: editing, context: context, report: &report)
                let after = await service.statistics()
                report["previewRawBase"] = ["fillsBefore": before.rawBaseFills, "fillsAfter": after.rawBaseFills,
                                            "hitsBefore": before.rawBaseHits, "hitsAfter": after.rawBaseHits]
            }
            let cases = pairedPreset || measureMask ? [] : (filterOnly ? filterCases : standardCases)
            var allInteractive: [Double] = [], coldInteractive: [Double] = [], warmInteractive: [Double] = []
            for (label, count, makeCommands) in cases {
                var interactive: [Double] = [], settled: [Double] = []
                for index in 1...count {
                    let step: Double = switch label {
                    case "exposure": 0.05
                    case "color": 0.025
                    case "filterIntensity": 12
                    default: 5
                    }
                    let value = Double(index) * step
                    let token = try editing.developmentSession.beginGesture(.init(group: nil, name: label), context: context)
                    let started = DispatchTime.now().uptimeNanoseconds
                    try editing.developmentSession.applyAtomically(makeCommands(value), title: label,
                        event: .init(context: context, control: .init(group: nil, name: label),
                            nativeInput: .capture(control: "performance." + label, phase: "change", nativeEvent: true, gestureID: token.id)), gesture: token)
                    try await wait(label + " interactive draw \(index)") {
                        editing.previews.primary.frameRecipe == editing.recipe
                            && editing.previews.primary.frame?.quality == .interactive
                            && editing.previews.primary.currentFrameWasDrawn
                    }
                    interactive.append(Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000)
                    let settling = DispatchTime.now().uptimeNanoseconds
                    try editing.developmentSession.endGesture(token, .commit)
                    if !filterOnly && (!interactiveBurst || index == count) {
                        try await wait(label + " settled draw \(index)", seconds: 60) {
                            editing.previews.primary.frameRecipe == editing.recipe
                                && editing.previews.primary.frame?.quality == .settled
                                && editing.previews.primary.currentFrameWasDrawn
                        }
                        settled.append(Double(DispatchTime.now().uptimeNanoseconds - settling) / 1_000_000)
                    }
                    XCTAssertEqual(editing.developmentContext, context)
                    XCTAssertNil(editing.message)
                    let route = editing.previews.primary.frame
                    print("PERF-ROUTE \(label) \(index) approximate=\(route?.approximate == true)")
                }
                allInteractive += interactive
                if let first = interactive.first { coldInteractive.append(first) }
                warmInteractive += interactive.dropFirst()
                report[label] = ["interactive": statistics(interactive), "settledAfterGesture": statistics(settled)]
            }
            report["allInteractive"] = statistics(allInteractive)
            report["coldInteractiveFirstPerCase"] = statistics(coldInteractive)
            report["warmInteractiveAfterFirstPerCase"] = statistics(warmInteractive)
            report["sourceSHA256After"] = try await Task.detached { try FileSafety.hash(source) }.value
            XCTAssertEqual(report["sourceSHA256After"] as? String, prepared.2)
            await editing.shutdown()
            await service.closeAll()
            editorDidClose = true
            if let adoptedMask {
                report["memoryAfterEditorShutdown"] = try Self.maskProcessMemory()
                try await Self.exportReopenedMask(library: library, workID: context.workID, layer: adoptedMask,
                                                  output: output, report: &report)
                let toggle = try XCTUnwrap(report["togglePixelComparison"] as? [String: Int])
                XCTAssertEqual(toggle["protectedMaximumRGBA16Difference"], 0, "Protected pixels changed when toggling the layer, including legacy work")
                let hashAfterExport = try await Task.detached { try FileSafety.hash(source) }.value
                report["sourceSHA256AfterExport"] = hashAfterExport
                XCTAssertEqual(hashAfterExport, prepared.2)
            }
        } catch {
            if !editorDidClose { await editing.shutdown(); await service.closeAll() }
            report["failure"] = error.localizedDescription
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: reportURL, options: .withoutOverwriting)
            throw error
        }
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: reportURL, options: .withoutOverwriting)
        print("EDITING-CANVAS-PERFORMANCE \(report)")
    }
}
