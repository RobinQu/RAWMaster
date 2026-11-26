import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
import RAWMasterImaging
@testable import RAWMaster

final class PhotosInspectorTextLayoutTests: XCTestCase {
    private var previousAccessibility: Any?
    @MainActor private func elements(_ window: NSWindow) -> [NSObject] {
        var pending: [NSObject] = [window], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let node = pending.popLast(), visited.count < 2_048 {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            let selector = NSSelectorFromString("accessibilityChildren")
            if node.responds(to: selector) {
                pending += ((node.perform(selector)?.takeUnretainedValue() as? [Any]) ?? []).compactMap { $0 as? NSObject }
            }
        }
        return result
    }
    @MainActor private func value(_ node: NSObject, _ key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        guard node.responds(to: selector) else { return nil }
        return node.perform(selector)?.takeUnretainedValue()
    }
    @MainActor private func node(_ id: String, in window: NSWindow) -> NSObject? {
        elements(window).first { value($0, "accessibilityIdentifier") as? String == id }
    }
    @MainActor private func frame(_ node: NSObject) throws -> NSRect {
        try XCTUnwrap(node.value(forKey: "accessibilityFrame") as? NSValue).rectValue
    }
    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        guard condition() else { XCTFail("The hosted accessibility state did not arrive"); throw CancellationError() }
    }
    @MainActor private func makeHost<V: View>(_ view: V, scheme: ColorScheme, width: CGFloat = 300)
        -> (NSWindow, NSHostingView<AnyView>) {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        previousAccessibility = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, scheme)
            .frame(width: width, height: 350, alignment: .topLeading).padding(8)
            .background(Color(nsColor: .controlBackgroundColor))))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: width + 16, height: 366),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host; window.makeKeyAndOrderFront(nil)
        return (window, host)
    }
    @MainActor private func close(_ window: NSWindow) {
        window.orderOut(nil); window.contentView = nil; window.close()
        NSApp.accessibilitySetValue(previousAccessibility, forAttribute: NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface"))
        previousAccessibility = nil
    }
    @MainActor private func bitmap(_ host: NSView) throws -> NSBitmapImageRep {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }
    @MainActor private func capture(_ host: NSView, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["RAWMASTER_CAPTURE_INSPECTOR_TEXT"] else { return }
        let root = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let data = try XCTUnwrap(try bitmap(host).representation(using: .png, properties: [:]))
        try data.write(to: root.appendingPathComponent(name))
    }

    @MainActor private final class SliderValue: ObservableObject {
        @Published var value = 52.0
    }
    private struct FocusSlider: View {
        @ObservedObject var model: SliderValue
        var body: some View {
            PhotosSliderRow(title: "滤镜强度", value: $model.value, range: 0...100, step: 1, digits: 0,
                identifier: "focus.slider", onChange: { model.value = $0 })
        }
    }
    @MainActor private func viewTree(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap { viewTree($0) }
    }

    @MainActor func testSliderAndIntegratedNumberKeepNativeInputWithoutFocusRings() async throws {
        for scheme in [ColorScheme.dark, .light] {
            let model = SliderValue()
            let (window, host) = makeHost(FocusSlider(model: model), scheme: scheme)
            defer { close(window) }
            try await wait { host.layoutSubtreeIfNeeded(); return self.viewTree(host).contains { $0 is NSSlider } }
            let slider = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSSlider }.first)
            let number = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSTextField }.first)
            XCTAssertEqual(slider.focusRingType, NSFocusRingType.none)
            XCTAssertEqual(slider.cell?.focusRingType, NSFocusRingType.none)
            XCTAssertEqual(number.focusRingType, NSFocusRingType.none)
            XCTAssertEqual(number.cell?.focusRingType, NSFocusRingType.none)
            let centre = slider.convert(.init(x: 20, y: slider.focusRingMaskBounds.midY), to: nil)
            func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
                try XCTUnwrap(NSEvent.mouseEvent(with: type, location: centre, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            }
            slider.mouseDown(with: try mouse(.leftMouseDown))
            slider.mouseUp(with: try mouse(.leftMouseUp))
            XCTAssertTrue(window.firstResponder === slider)
            XCTAssertEqual(model.value, 52, "A click focuses without jumping the value")
            let right = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}",
                isARepeat: false, keyCode: 124))
            slider.keyDown(with: right)
            XCTAssertEqual(model.value, 53)
            XCTAssertTrue(slider.accessibilityPerformDecrement())
            XCTAssertEqual(model.value, 52)
            try capture(host, name: "slider-focus-native-\(scheme == .dark ? "dark" : "light").png")

            number.selectText(nil)
            let editor = try XCTUnwrap(number.currentEditor() as? NSTextView)
            XCTAssertTrue(window.firstResponder === editor)
            editor.insertText("101", replacementRange: .init(location: 0, length: (editor.string as NSString).length))
            let selection = editor.selectedRange(), undo = editor.undoManager
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertTrue(number.currentEditor() === editor)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(editor.string, "101"); XCTAssertEqual(editor.selectedRange(), selection)
            XCTAssertTrue(editor.undoManager === undo); XCTAssertEqual(model.value, 52)
            editor.insertText("13.25", replacementRange: .init(location: 0, length: (editor.string as NSString).length))
            try capture(host, name: "number-focus-native-\(scheme == .dark ? "dark" : "light").png")
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
            XCTAssertEqual(model.value, 13.25, "Display precision does not truncate the stored input")
            XCTAssertFalse(number.currentEditor() === editor)
            try await wait { number.stringValue == "13" }
            number.selectText(nil)
            let cancelling = try XCTUnwrap(number.currentEditor() as? NSTextView)
            cancelling.insertText("78", replacementRange: .init(location: 0, length: (cancelling.string as NSString).length))
            cancelling.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
            XCTAssertEqual(model.value, 13.25)
        }
    }

    @MainActor func testDetailTextRhythmKeepsDescriptionsCompleteInBothAppearances() async throws {
        XCTAssertEqual(PhotosControlLayout.spacing, 4)
        XCTAssertEqual(PhotosControlLayout.descriptionSpacing, 7)
        XCTAssertEqual(PhotosControlLayout.groupSpacing, 12)
        for scheme in [ColorScheme.dark, .light] {
            let description = "可用于支持的马赛克 RAW 和系统能解码的 RGB 照片。"
            let view = VStack(alignment: .leading, spacing: PhotosControlLayout.groupSpacing) {
                VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                    Text("AI 降噪").accessibilityIdentifier("text.heading")
                    Text(description).photosInspectorParagraph().foregroundStyle(.secondary)
                        .accessibilityIdentifier("text.description")
                }.accessibilityElement(children: .contain).accessibilityIdentifier("text.firstGroup")
                VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                    Text("RAW 细节")
                    Text("Bayer · AHD · 保持原始分辨率").photosInspectorParagraph().foregroundStyle(.secondary)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("text.secondGroup")
            }
            let (window, host) = makeHost(view, scheme: scheme, width: 210)
            defer { close(window) }
            try await wait { host.layoutSubtreeIfNeeded(); return self.node("text.secondGroup", in: window) != nil }
            let heading = try frame(try XCTUnwrap(node("text.heading", in: window)))
            let paragraph = try frame(try XCTUnwrap(node("text.description", in: window)))
            let first = try frame(try XCTUnwrap(node("text.firstGroup", in: window)))
            let second = try frame(try XCTUnwrap(node("text.secondGroup", in: window)))
            XCTAssertEqual(heading.minY - paragraph.maxY, 7, accuracy: 1)
            XCTAssertEqual(first.minY - second.maxY, 12, accuracy: 1)
            XCTAssertGreaterThan(paragraph.height, heading.height, "The explanation wraps instead of clipping")
            try capture(host, name: "text-rhythm-native-\(scheme == .dark ? "dark" : "light").png")
        }
    }

    @MainActor func testSamplerRowsShowActualColourAndFullWidthFlatAction() async throws {
        let suite = "SamplerLayout-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let samplers = PhotosColorSamplers(defaults: defaults)
        samplers.bind(workID: "layout", sourceID: "colour")
        for x in [0.2, 0.5, 0.8] { XCTAssertTrue(samplers.place(.init(x: x, y: 0.5))) }
        let context = try XCTUnwrap(CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(.init(x: 0, y: 0, width: 16, height: 16))
        let image = NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .init(width: 16, height: 16))
        let frame = EditingPreviewBitmap(id: UUID(), image: image, leaseID: .init(), generation: 1,
            consumerID: .init(), revision: 1, quality: .settled, nativeSize: image.size, outputSize: image.size, approximate: false)
        let mapping = try DevelopmentGeometryV3().mapping(sourceSize: .init(width: 16, height: 16))
        for scheme in [ColorScheme.dark, .light] {
            var picks: [Int?] = []
            let view = PhotosColorSamplerRows(samplers: samplers, frame: frame, mapping: mapping) { picks.append($0) }
            let (window, host) = makeHost(view, scheme: scheme)
            defer { close(window) }
            try await wait {
                host.layoutSubtreeIfNeeded()
                return self.elements(window).contains {
                    (self.value($0, "accessibilityValue") as? String)?.contains("R 255") == true
                }
            }
            let add = try XCTUnwrap(node("photos.scopes.sampler.add", in: window))
            let addFrame = try self.frame(add)
            for i in 1...3 {
                let row = try self.frame(try XCTUnwrap(node("photos.scopes.sampler.row.\(i)", in: window)))
                XCTAssertEqual(row.width, addFrame.width, accuracy: 1)
                XCTAssertEqual(row.height, 32, accuracy: 1)
                XCTAssertNotNil(node("photos.scopes.sampler.manage.\(i)", in: window))
            }
            XCTAssertEqual(addFrame.height, 26, accuracy: 1)
            let press = NSSelectorFromString("accessibilityPerformPress")
            typealias Press = @convention(c) (AnyObject, Selector) -> Bool
            let implementation = try XCTUnwrap(add.method(for: press))
            XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(add, press))
            XCTAssertEqual(picks.count, 1); XCTAssertNil(picks[0])
            let pixels = try bitmap(host)
            let sampled = try XCTUnwrap(samplers.colors(frame: frame, mapping: mapping).first ?? nil)
            // colorAt does not preserve the bitmap profile in its NSColor; compare raw capture components.
            let expected = try XCTUnwrap(NSColor(srgbRed: Double(sampled.rgb.x), green: Double(sampled.rgb.y),
                blue: Double(sampled.rgb.z), alpha: 1).usingColorSpace(pixels.colorSpace))
            var matchingPixels = 0
            for y in 0..<pixels.pixelsHigh {
                for x in 0..<min(pixels.pixelsWide, 80) {
                    if let colour = pixels.colorAt(x: x, y: y),
                       abs(colour.redComponent - expected.redComponent) < 0.025,
                       abs(colour.greenComponent - expected.greenComponent) < 0.025,
                       abs(colour.blueComponent - expected.blueComponent) < 0.025 { matchingPixels += 1 }
                }
            }
            let scale = CGFloat(pixels.pixelsWide) / host.bounds.width * CGFloat(pixels.pixelsHigh) / host.bounds.height
            XCTAssertGreaterThan(CGFloat(matchingPixels) / scale, 600, "All three icons match sampled RGB in the capture colour space")
            try capture(host, name: "samplers-native-\(scheme == .dark ? "dark" : "light").png")
        }
    }

    @MainActor func testUnavailableSamplersKeepNumbersAndLimitOnlyDisablesAdding() async throws {
        let suite = "SamplerUnavailable-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let samplers = PhotosColorSamplers(defaults: defaults)
        samplers.bind(workID: "layout", sourceID: "unavailable")
        for i in 1...9 { XCTAssertTrue(samplers.place(.init(x: Double(i) / 10, y: 0.5))) }
        let (window, host) = makeHost(PhotosColorSamplerRows(samplers: samplers, frame: nil, mapping: nil) { _ in }, scheme: .dark)
        defer { close(window) }
        try await wait { host.layoutSubtreeIfNeeded(); return self.node("photos.scopes.sampler.row.9", in: window) != nil }
        let add = try XCTUnwrap(node("photos.scopes.sampler.add", in: window))
        XCTAssertEqual(add.value(forKey: "accessibilityEnabled") as? NSNumber, NSNumber(value: false))
        for i in 1...9 { XCTAssertNotNil(node("photos.scopes.sampler.manage.\(i)", in: window)) }
        XCTAssertTrue(elements(window).contains { value($0, "accessibilityValue") as? String == "当前画面外" })
        XCTAssertTrue(samplers.place(.init(x: 0.4, y: 0.6), replacing: 0))
        XCTAssertEqual(samplers.points.count, 9)
        samplers.remove(8)
        try await wait {
            host.layoutSubtreeIfNeeded()
            return self.node("photos.scopes.sampler.row.9", in: window) == nil
                && self.node("photos.scopes.sampler.add", in: window)?.value(forKey: "accessibilityEnabled") as? NSNumber == NSNumber(value: true)
        }
    }
}
