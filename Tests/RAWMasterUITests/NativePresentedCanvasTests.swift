import AppKit
import CoreMedia
import ImageIO
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

    static func register(source: URL, library: URL) throws -> AssetRecord {
        let store = try LibraryStore(databaseURL: library)
        let project = ProjectRecord(name: "Presented canvas benchmark")
        try store.saveProject(project)
        let imported = ImportSession(projectID: project.id, projectName: project.name,
            sourcePath: source.deletingLastPathComponent().path, mode: .reference, status: "completed",
            discovered: 1, completed: 1, scanCompleted: true)
        try store.saveSession(imported)
        guard PhotoRenderer.rawExtensions.contains(source.pathExtension.lowercased()),
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

    @MainActor func testOptInRealRAWPresentedCanvas() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["RAWMASTER_PRESENTED_CANVAS_JOB"], let path = env["RAWMASTER_PRESENTED_CANVAS_SOURCE"] else {
            throw XCTSkip("Opt-in presented canvas lab")
        }
        #if DEBUG
        throw XCTSkip("The presented canvas benchmark requires Release")
        #endif
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
        let app = AppModel(libraryURL: library, defaults: defaults)
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
            let context = try XCTUnwrap(editing.developmentContext), frame = try XCTUnwrap(editing.previews.primary.frame)
            guard let decoder = editing.recipe.adjustmentsV3?.rawDecoder, decoder == .flashRaw031 else {
                throw Failure.invalid("The fresh RAW work did not select the packaged FlashRaw decoder")
            }
            let canvas = try XCTUnwrap(findCanvas(host)), factor = window.backingScaleFactor
            guard !window.isKeyWindow, !window.isMainWindow,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                throw Failure.invalid("Benchmark window must stay in the background")
            }
            let fitted = ImageViewportGeometry.imageRect(pixelSize: frame.outputSize, viewport: canvas.bounds.size,
                transform: .init(), backingScale: factor, fitInsets: insets)
            let windowPhoto = canvas.convert(fitted, to: nil)
            let capturedPhoto = [windowPhoto.minX, window.frame.height - windowPhoto.maxY, windowPhoto.width, windowPhoto.height].map { Int(($0 * factor).rounded()) }
            guard abs(capturedPhoto[2] - 2368) <= 1, abs(capturedPhoto[3] - 1579) <= 1,
                  screenRect.contains(window.convertToScreen(windowPhoto)) else { throw Failure.invalid("Photo bounds: \(capturedPhoto), screen \(screenRect)") }
            let testBinary = try XCTUnwrap(Bundle(for: Self.self).executableURL)
            let meta: [String: Any] = ["id": window.windowNumber, "title": window.title, "pid": ProcessInfo.processInfo.processIdentifier,
                "bundle": NSRunningApplication.current.bundleIdentifier ?? "", "photoRectPixels": capturedPhoto,
                "previewPixels": [Int(frame.outputSize.width), Int(frame.outputSize.height)],
                "sourcePixels": [asset.width ?? 0, asset.height ?? 0], "sourceSHA256": context.sourceContentID,
                "testBundleSHA256": try FileSafety.hash(testBinary), "decoder": decoder.rawValue,
                "recipe": try JSONSerialization.jsonObject(with: JSONEncoder().encode(editing.recipe)), "scale": factor]
            try write(meta, to: job.appendingPathComponent("ready.json"))
            var sequence = 1
            while true {
                let requestFile = job.appendingPathComponent("request-\(sequence).json")
                try await waitFor("request \(sequence)", seconds: 120) { FileManager.default.fileExists(atPath: requestFile.path) }
                let request = try JSONDecoder().decode(Request.self, from: Data(contentsOf: requestFile))
                let reply = job.appendingPathComponent("reply-\(sequence).json")
                sequence += 1
                if request.action == "stop" { try write(["stopped": true], to: reply); break }
                guard !window.isKeyWindow, !window.isMainWindow,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    throw Failure.invalid("The test fixture unexpectedly received foreground focus")
                }
                do {
                    if request.action == "reset" {
                        try editing.developmentSession.apply(.resetAll, event: .init(context: context, control: .init(group: nil, name: "Reset fixture")))
                        try await waitFor("reset frame") { editing.previews.primary.frameRecipe == editing.recipe && editing.previews.primary.currentFrameWasDrawn }
                        try write(["reset": true], to: reply)
                    } else {
                        guard request.action == "set", let key = request.key, let target = request.value else { throw Failure.invalid("request") }
                        let sent = CMTimeConvertScale(CMClockGetTime(CMClockGetHostTimeClock()), timescale: 1_000_000_000, method: .default).value
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
                        try write(["sentNs": sent, "actual": actual.map { $0 as Any } ?? NSNull(), "accepted": accepted,
                                   "mapping": mapping, "recipeFingerprint": try EditingFingerprint.of(expected)], to: reply)
                    }
                } catch { try write(["error": String(describing: error)], to: reply) }
            }
            await editing.shutdown()
        } catch { try? write(["error": String(describing: error)], to: job.appendingPathComponent("failure.json")); await editing.shutdown(); throw error }
    }
}
