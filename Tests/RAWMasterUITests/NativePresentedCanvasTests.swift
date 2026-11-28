import AppKit
import CoreMedia
import Darwin
import Dispatch
import ImageIO
import Metal
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore
@testable import RAWMasterImaging

/// Release-only lab driver for benchmark-rawmaster-canvas.py. Input and frame timestamps
/// share the Core Media host clock. The external recorder observes this one window.
final class NativePresentedCanvasTests: XCTestCase {
    struct Request: Decodable {
        let action: String
        var key: String?
        var value: Double?
    }
    enum Failure: Error { case invalid(String) }

    @MainActor private func waitFor(_ description: String, seconds: Double = 45, _ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !ready() {
            guard ContinuousClock.now < deadline else { throw Failure.invalid("Timed out: " + description) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func write(_ object: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: url, options: .atomic)
    }

    static func register(source: URL, library: URL, requiresRAW: Bool = true) throws -> AssetRecord {
        let store = try LibraryStore(databaseURL: library)
        let project = ProjectRecord(name: "Presented canvas benchmark")
        try store.saveProject(project)
        let imported = ImportSession(projectID: project.id, projectName: project.name,
            sourcePath: source.deletingLastPathComponent().path, mode: .reference, status: "completed",
            discovered: 1, completed: 1, scanCompleted: true)
        try store.saveSession(imported)
        guard (!requiresRAW || PhotoRenderer.rawExtensions.contains(source.pathExtension.lowercased())),
              let image = CGImageSourceCreateWithURL(source as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [String: Any],
              let width = props[kCGImagePropertyPixelWidth as String] as? Int,
              let height = props[kCGImagePropertyPixelHeight as String] as? Int else { throw Failure.invalid("RAW dimensions") }
        let asset = try store.register(.init(sessionID: imported.id, projectID: project.id, projectName: project.name,
            sourcePath: source.path, currentPath: source.path, filename: source.lastPathComponent,
            fileSize: try FileSafety.stat(source).size, width: width, height: height,
            contentHash: try FileSafety.hash(source), importState: .ready))
        try store.completedDirectImport(imported)
        return asset
    }

    @MainActor private func findCanvas(_ view: NSView) -> ImageCanvas? {
        if let match = view as? ImageCanvas { return match }
        for child in view.subviews {
            if let match = findCanvas(child) { return match }
        }
        return nil
    }

    @MainActor private func apply(_ key: String, value: Double, editing: EditingController,
                                  context: EditingInteractionContext) throws -> (String, () -> Double?) {
        let session = editing.developmentSession
        let before = session.parameters
        var command: DevelopmentAdjustmentCommand?
        let mapping: String
        let read: () -> Double?
        let fields: [String: (WritableKeyPath<DevelopmentLightV3, Double>, Double)] = [
            "light-exposure": (\.exposure, 2), "light-contrast": (\.contrast, 100),
            "light-highlights": (\.highlights, 100), "light-shadows": (\.shadows, 100),
            "light-whites": (\.whites, 100), "light-blacks": (\.blackPoint, -100)]
        if let (path, scale) = fields[key] {
            var light = before.light
            light.enabled = true
            light[keyPath: path] = value / scale
            command = .setParameters(.light(light))
            mapping = "recipe = supplied / \(scale)"
            read = { session.parameters.light[keyPath: path] * scale }
        } else {
            switch key {
            case "color-temp-raw", "color-tint":
                guard let base = before.whiteBalance.resolvedState ?? editing.developmentWhiteBalanceBaseline else {
                    throw Failure.invalid("Missing RAW WB baseline")
                }
                command = try PhotosWhiteBalanceStateEditing.command(state: base, mode: .temperatureTint,
                    component: key == "color-temp-raw" ? .temperature : .tint, value: value)
                mapping = key == "color-temp-raw" ? "absolute Kelvin" : "native tint"
                read = {
                    guard case let .temperatureTint(t, v) = session.parameters.whiteBalance.adjustment else { return nil }
                    return key == "color-temp-raw" ? t : v
                }
            case "color-vibrance", "color-saturation":
                let path: WritableKeyPath<DevelopmentColorV3, Double> = key == "color-vibrance" ? \.vibrance : \.saturation
                var color = before.color
                color.enabled = true; color[keyPath: path] = value / 100
                command = .setParameters(.color(color))
                mapping = "recipe = supplied / 100"
                read = { session.parameters.color[keyPath: path] * 100 }
            case "effects-texture", "effects-clarity":
                let group: DevelopmentAdjustmentID = key == "effects-texture" ? .texture : .clarity
                command = try PhotosAdvancedDetailEditing.command(group, change: .amount(value), parameters: before)
                mapping = "amount"
                read = { try? PhotosAdvancedDetailEditing.value(group, in: session.parameters).amount }
            case "effects-dehaze":
                try editing.developmentDehazeInput.commit(value, context: context)
                mapping = "prepared dehaze amount"
                read = { session.parameters.advancedDetail.dehaze.amount }
            case "effects-pcv-amount", "effects-glow-amount", "effects-grain-amount":
                var effects = before.effects ?? .init()
                if key == "effects-pcv-amount" { effects.postCropVignette = .init(enabled: true, amount: value) }
                else if key == "effects-glow-amount" { effects.glow = .init(enabled: true, amount: value) }
                else { effects.enabled = true; effects.grain = value / 100 }
                command = .setEffects(effects)
                mapping = key == "effects-grain-amount" ? "recipe = supplied / 100" : "amount"
                read = {
                    let current = session.parameters.effects
                    if key == "effects-pcv-amount" { return current?.postCropVignette?.amount }
                    if key == "effects-glow-amount" { return current?.glow?.amount }
                    return current.map { $0.grain * 100 }
                }
            default: throw Failure.invalid("Unknown operation " + key)
            }
        }
        if let command {
            try session.apply(command, event: .init(context: context, control: .init(group: nil, name: key),
                nativeInput: .capture(control: key, phase: "discrete", nativeEvent: false)))
        }
        return (mapping, read)
    }

    @MainActor func testOptInRealRAWFreeZoomKeepsMagnificationAndSamplesAtTheViewport() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_PRESENTED_CANVAS_SOURCE"] else {
            throw XCTSkip("Set RAWMASTER_PRESENTED_CANVAS_SOURCE to a RAW fixture")
        }
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("fixture.sqlite")
        let asset = try Self.register(source: URL(fileURLWithPath: path), library: library)
        let name = "ZoomCanvas-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let restoreMode = PreviewPerformancePreferences.mode
        defer { defaults.removePersistentDomain(forName: name); PreviewPerformancePreferences.mode = restoreMode }
        let model = AppModel(libraryURL: library, defaults: defaults)
        let editing = try XCTUnwrap(model.editing)
        let rect = CGRect(x: 0, y: 0, width: 1280, height: 700)
        let window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: EditingImageCanvas(editing: editing).environmentObject(model))
        window.contentView = host
        window.setFrame(rect, display: false)
        defer { window.contentView = nil; window.close() }
        let drawing = try XCTUnwrap(CGContext(data: nil, width: 1280, height: 700, bitsPerComponent: 8,
            bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        func drawCanvas() {
            host.layoutSubtreeIfNeeded()
            guard let canvas = findCanvas(host) else { return }
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            NSGraphicsContext.current = NSGraphicsContext(cgContext: drawing, flipped: true)
            canvas.draw(canvas.bounds)
        }
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await waitFor("initial RAW frame") { editing.previews.primary.frame != nil || editing.previews.primary.error != nil }
            XCTAssertNil(editing.previews.primary.error)
            _ = try XCTUnwrap(editing.previews.primary.frame)
            editing.beginDevelopmentInterface()
            try await waitFor("development context") { editing.developmentContext != nil }
            try await waitFor("current RAW frame") {
                drawCanvas()
                return editing.previews.primary.currentFrameWasDrawn
            }
            let canvas = try XCTUnwrap(findCanvas(host))
            let anchor = CGPoint(x: canvas.bounds.midX + 100, y: canvas.bounds.midY + 30)
            var balancedRaster: Data?
            for mode in PreviewPerformanceMode.allCases {
                PreviewPerformancePreferences.mode = mode
                let start = canvas.viewportSnapshot
                let fitDensity = start.imageRect.width * start.backingScale / start.imagePixelSize.width
                canvas.handleZoom(factor: 1, at: anchor, phase: .began)
                canvas.handleZoom(factor: 0.65 / fitDensity, at: anchor, phase: .changed)
                let stopped = canvas.viewportSnapshot
                XCTAssertFalse(editing.actualPixels)
                if mode == .turbo {
                    XCTAssertNotEqual(editing.previews.primary.frame?.quality, .detail)
                } else {
                    try await waitFor("balanced requests details during zoom") { editing.previews.primary.frame?.quality == .detail }
                }
                canvas.handleZoom(factor: 1, at: anchor, phase: .ended)
                try await waitFor("stable detail at \(mode)") {
                    drawCanvas()
                    return editing.previews.primary.currentFrameWasDrawn && editing.previews.primary.frame?.quality == .detail
                }
                let frame = try XCTUnwrap(editing.previews.primary.frame)
                let draw = try XCTUnwrap(editing.previews.primary.currentAcceptedDraw)
                let landed = canvas.viewportSnapshot
                XCTAssertEqual(CGSize(width: draw.imagePixelWidth, height: draw.imagePixelHeight), frame.outputSize)
                XCTAssertEqual(landed.imagePixelSize, frame.nativeSize)
                XCTAssertEqual(landed.transform, stopped.transform)
                XCTAssertEqual(landed.imageRect, stopped.imageRect)
                XCTAssertEqual(landed.imageRect.width * landed.backingScale / frame.nativeSize.width, 0.65, accuracy: 0.0001)
                XCTAssertFalse(frame.approximate)
                let region = frame.window?.size ?? CGSize(width: 1, height: 1)
                XCTAssertEqual(frame.outputSize.width, frame.nativeSize.width * 0.65 * region.width, accuracy: 1)
                XCTAssertEqual(frame.outputSize.height, frame.nativeSize.height * 0.65 * region.height, accuracy: 1)
                let raster = try XCTUnwrap(frame.image.tiffRepresentation)
                if mode == .balanced { balancedRaster = raster } else { XCTAssertEqual(raster, balancedRaster) }
                print("Zoom \(mode.rawValue): \(frame.nativeSize) → \(frame.outputSize) visible at 65%, window \(String(describing: frame.window))")
                editing.requestCanvasCommand(.fit)
                try await waitFor("return to FIT") {
                    drawCanvas()
                    return canvas.viewportSnapshot.transform == .init() && editing.previews.primary.frame?.quality == .settled
                }
            }
            await editing.shutdown()
        } catch { await editing.shutdown(); throw error }
    }

    @MainActor func testOptInRealRAWPresentedCanvas() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["RAWMASTER_PRESENTED_CANVAS_JOB"], let path = env["RAWMASTER_PRESENTED_CANVAS_SOURCE"] else {
            throw XCTSkip("Opt-in presented canvas lab")
        }
        #if DEBUG
        throw XCTSkip("The presented canvas benchmark requires Release")
        #endif
        let diagnostics = env["RAWMASTER_PRESENTED_CANVAS_DIAGNOSTICS"] == "1"
        let directActualPixelEntry = env["RAWMASTER_PRESENTED_CANVAS_DIRECT_1TO1"] == "1"
        let requestedROI: [Int]?
        if let encodedROI = env["RAWMASTER_PRESENTED_CANVAS_SOURCE_ROI"] {
            let parts = encodedROI.split(separator: ",", omittingEmptySubsequences: false)
            let pixels = parts.compactMap { Int($0) }
            guard parts.count == 4, pixels.count == 4, pixels.prefix(2).allSatisfy({ $0 >= 0 }),
                  pixels.suffix(2).allSatisfy({ $0 > 0 }) else { throw Failure.invalid("Source ROI") }
            requestedROI = pixels
        } else { requestedROI = nil }
        _ = NSApplication.shared
        // A foreground editor receives normal interactive scheduling. Keep the deliberately
        // background test host out of App Nap without taking focus or preventing idle sleep.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Measuring native photo presentation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        let job = URL(fileURLWithPath: folder), source = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let library = job.appendingPathComponent("fixture.sqlite")
        let asset = try await Task.detached { try Self.register(source: source, library: library) }.value
        let suite = "PresentedCanvas-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let previewService: DevelopmentPreviewService
        if let setting = env["RAWMASTER_PRESENTED_CANVAS_RAW_BASE_CACHE_BYTES"] {
            guard let bytes = Int(setting), (0...1_073_741_824).contains(bytes) else {
                throw Failure.invalid("RAW base cache bytes")
            }
            previewService = DevelopmentPreviewService(policy: .init(rawBaseCacheBytes: bytes,
                interactiveEvaluation: .proxyV1, settledTransport: .viewport))
        } else {
            previewService = .shared
        }
        let app = AppModel(libraryURL: library, defaults: defaults,
                           editingPreviewBackend: SharedEditingPreviewBackend(service: previewService))
        let editing = try XCTUnwrap(app.editing)
        let screen = try XCTUnwrap(NSScreen.main), scale = screen.backingScaleFactor
        let insets = EditingLayout.fitInsets
        let size = CGSize(width: 2368 / scale + insets.left + insets.right,
                          height: 1579 / scale + insets.top + insets.bottom)
        let screenRect = screen.frame
        let rect = CGRect(x: screenRect.midX - size.width / 2, y: screenRect.midY - size.height / 2, width: size.width, height: size.height)
        let window = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = "RAWMaster Presented Canvas " + UUID().uuidString
        window.isReleasedWhenClosed = false
        window.isFloatingPanel = false; window.hidesOnDeactivate = false; window.ignoresMouseEvents = true
        window.level = .normal
        let host = NSHostingView(rootView: EditingImageCanvas(editing: editing).environmentObject(app))
        window.contentView = host; window.setFrame(rect, display: true); window.orderBack(nil)
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        do {
            editing.isPresented = true; editing.focus(asset)
            try await waitFor("open") { editing.work != nil && editing.previews.primary.frame != nil }
            editing.beginDevelopmentInterface()
            try await waitFor("development context") { editing.developmentContext != nil }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            try await waitFor("settled display") {
                editing.previews.primary.currentFrameWasDrawn && editing.previews.primary.frame?.quality != .interactive
            }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let canvas = try XCTUnwrap(findCanvas(host)), factor = window.backingScaleFactor
            let sourceWidth = try XCTUnwrap(asset.width), sourceHeight = try XCTUnwrap(asset.height)
            func capturedBackingRect(_ rect: CGRect) -> [CGFloat] {
                let inWindow = canvas.convert(rect, to: nil)
                return [inWindow.minX, window.frame.height - inWindow.maxY, inWindow.width, inWindow.height]
                    .map { $0 * factor }
            }
            func roundedPixels(_ rect: [CGFloat]) -> [Int] { rect.map { Int($0.rounded()) } }
            struct DetailCapture: Equatable {
                let photoRect: [CGFloat]
                let roiRect: [CGFloat]
                let frameWindow: CGRect?
                let visibleWindow: CGRect
                let outputSize: CGSize
            }
            var nativeDetail: DetailCapture?
            var nativeEntry: [String: Any]?
            func encodeWindow(_ rect: CGRect?) -> Any {
                guard let rect else { return NSNull() }
                return [rect.minX, rect.minY, rect.width, rect.height]
            }
            func detailCapture(_ requested: [Int]) throws -> DetailCapture {
                let snapshot = canvas.viewportSnapshot
                let frame = try XCTUnwrap(editing.previews.primary.frame)
                guard editing.actualPixels, frame.quality == .detail, !frame.approximate,
                      frame.nativeSize == CGSize(width: sourceWidth, height: sourceHeight),
                      snapshot.backingScale == factor,
                      abs(snapshot.imageRect.width * factor / Double(sourceWidth) - 1) < 0.0001,
                      abs(snapshot.imageRect.height * factor / Double(sourceHeight) - 1) < 0.0001 else {
                    throw Failure.invalid("No exact source pixels at physical 1:1")
                }
                let unit = CGRect(x: Double(requested[0]) / Double(sourceWidth), y: Double(requested[1]) / Double(sourceHeight),
                    width: Double(requested[2]) / Double(sourceWidth), height: Double(requested[3]) / Double(sourceHeight))
                let served = frame.window ?? CGRect(x: 0, y: 0, width: 1, height: 1)
                guard let visible = ImageViewportGeometry.visibleWindow(destination: snapshot.imageRect, bounds: canvas.bounds),
                      ImageViewportGeometry.window(served, covers: visible),
                      ImageViewportGeometry.window(visible, covers: unit) else {
                    throw Failure.invalid("The exact detail bitmap must cover the visible source and the sampled ROI")
                }
                let sourceGrid = [served.minX * CGFloat(sourceWidth), served.minY * CGFloat(sourceHeight),
                                  served.width * CGFloat(sourceWidth), served.height * CGFloat(sourceHeight)]
                guard sourceGrid.allSatisfy({ abs($0 - $0.rounded()) <= 0.01 }),
                      frame.outputSize == CGSize(width: sourceGrid[2].rounded(), height: sourceGrid[3].rounded()) else {
                    throw Failure.invalid("The presented detail bitmap resampled its source window")
                }
                let roi = ImageViewportGeometry.windowRect(unit, in: snapshot.imageRect)
                guard canvas.bounds.contains(roi), screenRect.contains(window.convertToScreen(canvas.convert(roi, to: nil))) else {
                    throw Failure.invalid("Source ROI fell outside the physical canvas")
                }
                let physical = capturedBackingRect(roi), photo = capturedBackingRect(snapshot.imageRect)
                guard (photo + physical).allSatisfy({ abs($0 - $0.rounded()) <= 0.01 }),
                      Array(roundedPixels(physical).suffix(2)) == Array(requested.suffix(2)) else {
                    throw Failure.invalid("ROI geometry mismatch: \(physical)")
                }
                return DetailCapture(photoRect: photo, roiRect: physical,
                                     frameWindow: frame.window, visibleWindow: visible, outputSize: frame.outputSize)
            }
            if let requestedROI {
                guard requestedROI[0] <= sourceWidth - requestedROI[2], requestedROI[1] <= sourceHeight - requestedROI[3] else {
                    throw Failure.invalid("ROI falls outside the source")
                }
                if directActualPixelEntry {
                    let submitted = DispatchTime.now().uptimeNanoseconds
                    editing.enterActualPixels(nativeEvent: true)
                    nativeEntry = ["mode": "native-command", "submitUptimeNs": submitted,
                                   "firstRequestWindow": encodeWindow(editing.detailWindow),
                                   "firstRequestRevision": editing.previews.primary.currentRevision]
                } else {
                    let canvasRect = canvas.viewportSnapshot.imageRect
                    let x = Double(requestedROI[0]) + Double(requestedROI[2]) / 2
                    let y = Double(requestedROI[1]) + Double(requestedROI[3]) / 2
                    let anchor = NSPoint(x: canvasRect.minX + x * canvasRect.width / Double(sourceWidth),
                                         y: canvasRect.minY + y * canvasRect.height / Double(sourceHeight))
                    let doubleClick = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown,
                        location: canvas.convert(anchor, to: nil), modifierFlags: [],
                        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                        eventNumber: 1, clickCount: 2, pressure: 1))
                    canvas.mouseDown(with: doubleClick)
                }
                try await waitFor("exact detail at the requested source ROI") {
                    window.displayIfNeeded()
                    guard editing.previews.primary.currentFrameWasDrawn, let capture = try? detailCapture(requestedROI) else { return false }
                    if nativeEntry != nil, nativeEntry?["firstDrawRevision"] == nil,
                       let draw = editing.previews.primary.currentAcceptedDraw {
                        nativeEntry?["firstDrawRevision"] = editing.previews.primary.displayedRevision
                        nativeEntry?["firstDrawWindow"] = encodeWindow(capture.frameWindow)
                        nativeEntry?["firstDrawUptimeNs"] = draw.drawReturnedUptimeNanoseconds
                    }
                    return !directActualPixelEntry || capture.frameWindow == editing.detailWindow
                }
                nativeDetail = try detailCapture(requestedROI)
            }
            let context = try XCTUnwrap(editing.developmentContext), frame = try XCTUnwrap(editing.previews.primary.frame)
            guard let decoder = editing.recipe.adjustmentsV3?.rawDecoder, decoder == .flashRaw031 else {
                throw Failure.invalid("The fresh RAW work did not select the packaged FlashRaw decoder")
            }
            guard !window.isKeyWindow, !window.isMainWindow,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw Failure.invalid("Benchmark window must stay in the background")
            }
            let capturedPhoto: [Int]
            if let nativeDetail {
                capturedPhoto = roundedPixels(nativeDetail.photoRect)
            } else {
                let fitted = ImageViewportGeometry.imageRect(pixelSize: frame.outputSize, viewport: canvas.bounds.size,
                    transform: .init(), backingScale: factor, fitInsets: insets)
                capturedPhoto = roundedPixels(capturedBackingRect(fitted))
                guard abs(capturedPhoto[2] - 2368) <= 1, abs(capturedPhoto[3] - 1579) <= 1,
                      screenRect.contains(window.convertToScreen(canvas.convert(fitted, to: nil))) else {
                    throw Failure.invalid("Photo bounds: \(capturedPhoto), screen \(screenRect)")
                }
            }
            let testBinary = try XCTUnwrap(Bundle(for: Self.self).executableURL)
            var meta: [String: Any] = ["id": window.windowNumber, "title": window.title, "pid": ProcessInfo.processInfo.processIdentifier,
                "bundle": NSRunningApplication.current.bundleIdentifier ?? "", "photoRectPixels": capturedPhoto,
                "previewPixels": [Int(frame.outputSize.width), Int(frame.outputSize.height)],
                "sourcePixels": [asset.width ?? 0, asset.height ?? 0], "sourceSHA256": context.sourceContentID,
                "testBundleSHA256": try FileSafety.hash(testBinary), "decoder": decoder.rawValue,
                "recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(editing.recipe)), "scale": factor]
            if let requestedROI, let nativeDetail {
                meta["sourceROIPixels"] = requestedROI
                meta["sourceROIWindowPixels"] = roundedPixels(nativeDetail.roiRect)
                meta["photoWindowRectPixelsFloat"] = nativeDetail.photoRect
                meta["roiWindowRectPixelsFloat"] = nativeDetail.roiRect
                if let crop = nativeDetail.frameWindow {
                    meta["detailWindowNormalized"] = [crop.minX, crop.minY, crop.width, crop.height]
                } else {
                    meta["detailWindowNormalized"] = NSNull()
                }
                let visible = nativeDetail.visibleWindow
                meta["visibleSourceWindowNormalized"] = [visible.minX, visible.minY, visible.width, visible.height]
                meta["detailPixelSize"] = [Int(nativeDetail.outputSize.width), Int(nativeDetail.outputSize.height)]
                meta["physicalMagnification"] = 1
                meta["approximate"] = frame.approximate
                meta["previewMode"] = PreviewPerformancePreferences.mode.rawValue
                meta["detailCounters"] = await detailCounters(previewService)
                if let nativeEntry { meta["nativeEntry"] = nativeEntry }
            }
            if diagnostics { meta["diagnosticsEnabled"] = true }
            try write(meta, to: job.appendingPathComponent("ready.json"))
            var sequence = 1
            while true {
                let requestFile = job.appendingPathComponent("request-\(sequence).json")
                try await waitFor("request \(sequence)", seconds: 120) { FileManager.default.fileExists(atPath: requestFile.path) }
                let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestFile))
                let reply = job.appendingPathComponent("reply-\(sequence).json")
                sequence += 1
                if request.action == "stop" {
                    if diagnostics {
                        let telemetry = ImagePerformanceTelemetry.shared.snapshot()
                        try JSONEncoder().encode(telemetry).write(to: job.appendingPathComponent("telemetry.json"), options: .atomic)
                    }
                    var stopped: [String: Any] = ["stopped": true]
                    if requestedROI != nil { stopped["detailCounters"] = await detailCounters(previewService) }
                    try write(stopped, to: reply)
                    break
                }
                guard !window.isKeyWindow, !window.isMainWindow,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    throw Failure.invalid("The test fixture unexpectedly received foreground focus")
                }
                do {
                    if request.action == "reset" {
                        try editing.developmentSession.apply(.resetAll, event: .init(context: context, control: .init(group: nil, name: "Reset fixture")))
                        try await waitFor("reset frame") { editing.previews.primary.frameRecipe == editing.recipe && editing.previews.primary.currentFrameWasDrawn }
                        try write(["reset": true], to: reply)
                    } else if request.action == "pan-native", let initial = nativeDetail {
                        let evidence = try await verifyPhysicalPan(canvas, window: window, editing: editing,
                            visible: initial.visibleWindow, served: try XCTUnwrap(initial.frameWindow))
                        try write(evidence, to: reply)
                    } else if request.action == "audit-detail-cache", requestedROI != nil {
                        let work = try XCTUnwrap(editing.work)
                        let before = await detailCounters(previewService)
                        let second = try await previewService.open(source: .raw(work.source))
                        let twoLeases = await detailCounters(previewService)
                        await previewService.close(second.id)
                        await previewService.handleMemoryPressure()
                        let deadline = ContinuousClock.now + .seconds(5)
                        while await previewService.statistics().cachedBitmapBytes != 0 {
                            guard ContinuousClock.now < deadline else { throw Failure.invalid("Detail cache did not drain") }
                            try await Task.sleep(for: .milliseconds(10))
                        }
                        XCTAssertTrue(editing.actualPixels)
                        let pressured = await detailCounters(previewService)
                        try write(["before": before, "withSecondLease": twoLeases, "afterPressure": pressured], to: reply)
                    } else {
                        guard request.action == "set", let key = request.key, let target = request.value else { throw Failure.invalid("request") }
                        let sentUptimeBefore: UInt64? = diagnostics ? DispatchTime.now().uptimeNanoseconds : nil
                        let sent = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default).value
                        let sentUptimeAfter: UInt64? = diagnostics ? DispatchTime.now().uptimeNanoseconds : nil
                        let (mapping, read) = try apply(key, value: target, editing: editing, context: context)
                        if key == "effects-dehaze" {
                            try await waitFor("dehaze preparation", seconds: 45) { !editing.developmentDehazeInput.hasPendingInput }
                        }
                        let actual = read()
                        let accepted = actual.map { abs($0 - target) < 0.00001 } ?? false
                        let expected = editing.recipe
                        if accepted {
                            try await waitFor("settled native canvas for \(key)", seconds: 45) {
                                editing.previews.primary.frameRecipe == expected && editing.previews.primary.currentFrameWasDrawn &&
                                    editing.previews.primary.frame?.quality != .interactive
                            }
                        }
                        if accepted, let requestedROI, try detailCapture(requestedROI) != nativeDetail {
                            throw Failure.invalid("Physical ROI changed after edit")
                        }
                        var response: [String: Any] = ["sentNs": sent, "actual": actual.map { $0 as Any } ?? NSNull(),
                            "accepted": accepted, "mapping": mapping, "recipeFingerprint": try EditingFingerprint.of(expected)]
                        if let sentUptimeBefore, let sentUptimeAfter {
                            var inputDiagnostics: [String: Any] = ["sentUptimeBeforeNs": sentUptimeBefore, "sentUptimeAfterNs": sentUptimeAfter]
                            let primary = editing.previews.primary
                            if accepted, let draw = primary.currentAcceptedDraw {
                                inputDiagnostics["currentAcceptedDraw"] = ["frameID": draw.frameID.uuidString,
                                    "revision": primary.displayedRevision,
                                    "drawBeganUptimeNs": draw.drawBeganUptimeNanoseconds,
                                    "drawReturnedUptimeNs": draw.drawReturnedUptimeNanoseconds] as [String: Any]
                            }
                            response["diagnostics"] = inputDiagnostics
                        }
                        try write(response, to: reply)
                    }
                } catch { try write(["error": String(describing: error)], to: reply) }
            }
            await editing.shutdown()
        } catch { try? write(["error": String(describing: error)], to: job.appendingPathComponent("failure.json")); await editing.shutdown(); throw error }
    }

    @MainActor private func verifyPhysicalPan(_ canvas: ImageCanvas, window: NSWindow, editing: EditingController,
                                              visible: CGRect, served: CGRect) async throws -> [String: Any] {
        let pane = editing.previews.primary
        let original = try XCTUnwrap(pane.frame)
        let revision = pane.currentRevision
        let viewport = canvas.viewportSnapshot
        let width = viewport.imageRect.width
        let guardBand = (served.maxX - visible.maxX) * width
        let outside = guardBand + 24 / viewport.backingScale
        guard guardBand > 10, outside < (1 - visible.maxX) * width else { throw Failure.invalid("No pan travel") }
        let center = CGPoint(x: canvas.bounds.midX, y: canvas.bounds.midY)
        func event(_ type: NSEvent.EventType, offset: CGFloat = 0) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: canvas.convert(
                CGPoint(x: center.x - offset, y: center.y), to: nil), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func visibleWindow() throws -> CGRect {
            try XCTUnwrap(ImageViewportGeometry.visibleWindow(destination: canvas.viewportSnapshot.imageRect, bounds: canvas.bounds))
        }
        canvas.mouseDown(with: try event(.leftMouseDown))
        defer {
            if let release = try? event(.leftMouseUp) { canvas.mouseUp(with: release) }
        }
        canvas.mouseDragged(with: try event(.leftMouseDragged, offset: guardBand / 2))
        let inner = try visibleWindow()
        XCTAssertGreaterThan(inner.minX, visible.minX)
        XCTAssertTrue(ImageViewportGeometry.window(served, covers: inner, tolerance: 1e-9))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(pane.currentRevision, revision)
        XCTAssertEqual(pane.frame?.id, original.id)

        canvas.mouseDragged(with: try event(.leftMouseDragged, offset: outside))
        let target = try visibleWindow()
        XCTAssertFalse(ImageViewportGeometry.window(served, covers: target, tolerance: 1e-9))
        canvas.mouseDragged(with: try event(.leftMouseDragged))
        try await Task.sleep(for: .milliseconds(160))
        XCTAssertEqual(try visibleWindow(), visible)
        XCTAssertEqual(pane.currentRevision, revision)
        XCTAssertEqual(pane.frame?.id, original.id)

        let began = DispatchTime.now().uptimeNanoseconds
        canvas.mouseDragged(with: try event(.leftMouseDragged, offset: outside))
        try await waitFor("exact pixels after crossing the served window") {
            window.displayIfNeeded()
            guard pane.currentFrameWasDrawn, let frame = pane.frame, frame.id != original.id,
                  frame.quality == .detail, !frame.approximate, let region = frame.window else { return false }
            return ImageViewportGeometry.window(region, covers: target, tolerance: 1e-9)
        }
        let frame = try XCTUnwrap(pane.frame)
        XCTAssertEqual(frame.nativeSize, original.nativeSize)
        XCTAssertEqual(pane.currentRevision, revision + 1)
        XCTAssertTrue(editing.actualPixels)
        let draw = try XCTUnwrap(pane.currentAcceptedDraw)
        let region = try XCTUnwrap(frame.window)
        return ["warmFrameID": original.id.uuidString, "outsideFrameID": frame.id.uuidString,
                "startingRevision": revision, "endingRevision": pane.currentRevision,
                "visibleTarget": [target.minX, target.minY, target.width, target.height],
                "servedTarget": [region.minX, region.minY, region.width, region.height],
                "windowPixels": [Int(frame.outputSize.width), Int(frame.outputSize.height)],
                "outsideToDrawMs": Double(draw.drawReturnedUptimeNanoseconds - began) / 1_000_000]
    }

    @MainActor private func detailCounters(_ service: DevelopmentPreviewService) async -> [String: Any] {
        let stats = await service.statistics()
        let flash = FlashRawCanonicalTexturePool.shared.statistics()
        var values: [String: Any] = ["completedRenders": stats.completedRenders, "cacheHits": stats.cacheHits,
            "cachedBitmapBytes": stats.cachedBitmapBytes, "rawBaseResidentBytes": stats.rawBaseResidentBytes,
            "rawBaseReservedBytes": stats.rawBaseReservedBytes, "rawBaseBuildingBytes": stats.rawBaseBuildingBytes,
            "rawBasePinnedBytes": stats.rawBasePinnedBytes, "rawBaseRetiredBytes": stats.rawBaseRetiredBytes,
            "rawBaseFills": stats.rawBaseFills, "flashRawTextureResidentBytes": flash.residentBytes]
        if ProcessInfo.processInfo.environment["RAWMASTER_PRESENTED_CANVAS_DIAGNOSTICS"] == "1" {
            var memory = task_vm_info_data_t()
            var words = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.stride)
            let status = withUnsafeMutablePointer(to: &memory) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(words)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &words)
                }
            }
            if status == KERN_SUCCESS {
                values["processPeakPhysicalFootprintBytes"] = memory.ledger_phys_footprint_peak
            }
            if let device = MTLCreateSystemDefaultDevice() {
                values["metalAllocatedBytesAtObservation"] = device.currentAllocatedSize
            }
        }
        return values
    }
}
