import AppKit
import SwiftUI
import XCTest
@testable import RAWMasterCore
@testable import RAWMaster

final class EditingLayoutInteractionTests: XCTestCase {
    @MainActor private func wait(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<500 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for editing layout", file: file, line: line)
        throw CancellationError()
    }

    @MainActor private func axValue(_ element: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }

    private func press(_ element: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(element.responds(to: selector))
        let implementation = try XCTUnwrap(element.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(element, selector))
    }

    @MainActor private func accessibleElements(_ window: NSWindow) -> [NSObject] {
        var pending: [NSObject] = [window], visited = Set<ObjectIdentifier>(), result: [NSObject] = []
        while let node = pending.popLast(), visited.count < 2_048 {
            guard visited.insert(ObjectIdentifier(node)).inserted else { continue }
            result.append(node)
            pending += ((axValue(node, "accessibilityChildren") as? [Any]) ?? []).compactMap { $0 as? NSObject }
        }
        return result
    }

    @MainActor func testEditingLayoutExposesLeftRailFilmstripAndFloatingCrop() async throws {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }

        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
            editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: fixture.assets[0].projectID)
        model.select(fixture.assets[0]); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        try await wait { editing.work != nil && editing.preview != nil }

        let host = NSHostingView(rootView: WorkbenchView().environmentObject(model)
            .frame(width: 1440, height: 900))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer {
            window.orderOut(nil); window.contentView = nil; window.close()
        }
        window.makeKeyAndOrderFront(nil)
        do {
            try await wait {
                // Some headless XCTest hosts never deliver didBecomeKey. Activate the same public
                // interface entry used by the real inspector rather than fabricating its context.
                if editing.developmentToolsPaused { editing.beginDevelopmentInterface() }
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let elements = accessibleElements(window)
                let ids = elements.compactMap { axValue($0, "accessibilityIdentifier") as? String }
                let filmstripPhoto = model.sequenceBrowserLayout.segments.contains { segment in
                    segment.assets.contains { $0.id == fixture.assets[0].id }
                }
                return ids.contains("editing.darkroom") && ids.contains("editing.leftRail.filters")
                    && filmstripPhoto && ids.contains("editing.beforeAfter") && ids.contains("editing.crop")
                    && !ids.contains("photos.tool.裁切与拉直")
            }
        } catch {
            let ids = accessibleElements(window).compactMap { axValue($0, "accessibilityIdentifier") as? String }
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "output/tools/diagnostics/darkroom-layout-failure.png"))
                }
            }
            XCTFail("Missing editing layout identifiers: \(ids); context=\(editing.developmentContext != nil), presentation=\(editing.developmentPresentationContext != nil), loading=\(editing.loading), stage=\(editing.stage), presented=\(editing.isPresented), paused=\(editing.developmentToolsPaused), ready=\(editing.sourceReady), inspect=\(editing.previews.primary.canInspectDevelopmentSource), message=\(editing.message ?? "nil")")
            await editing.shutdown()
            throw error
        }
        if ProcessInfo.processInfo.environment["RAWMASTER_CAPTURE_LAYOUT"] == "1",
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "output/tools/diagnostics/darkroom-layout-current.png"))
            }
        }

        let curvesTab = try XCTUnwrap(accessibleElements(window).first {
            axValue($0, "accessibilityIdentifier") as? String == "photos.tool.曲线"
        })
        try press(curvesTab)
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let ids = accessibleElements(window).compactMap { axValue($0, "accessibilityIdentifier") as? String }
            return ids.contains("photos.curves.section") && !ids.contains("photos.whiteBalance.section")
        }

        _ = try XCTUnwrap(accessibleElements(window).first {
            axValue($0, "accessibilityIdentifier") as? String == "editing.beforeAfter"
        })
        editing.toggleBeforeAfter()
        XCTAssertTrue(editing.comparing)
        XCTAssertEqual(editing.comparisonVersionID, editing.work?.originalVersionID)
        try await wait { editing.previews.comparison.frame != nil }
        editing.toggleBeforeAfter()
        XCTAssertFalse(editing.comparing)
        editing.changeDevelopmentPage(.crop, context: try XCTUnwrap(editing.developmentContext))
        XCTAssertTrue(editing.cropEditing)
        XCTAssertEqual(editing.developmentSession.page, .crop)
        try await wait {
            if editing.developmentToolsPaused { editing.beginDevelopmentInterface() }
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return editing.developmentCropFrame(context: try! XCTUnwrap(editing.developmentContext)) != nil
        }
        do {
            try await wait {
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                let elements = accessibleElements(window)
                let labels = elements.compactMap { axValue($0, "accessibilityLabel") as? String }
                let ids = elements.compactMap { axValue($0, "accessibilityIdentifier") as? String }
                return labels.filter { $0 == "逆时针旋转" || $0 == "顺时针旋转" }.isEmpty
                    && !ids.contains(where: { $0.hasPrefix("photos.crop.cornerRotate.") })
                    && ids.contains("photos.crop.cancel") && ids.contains("photos.crop.done")
                    && ids.contains("photos.crop.reset") && !ids.contains("photos.tool.基础")
            }
        } catch {
            let ids = accessibleElements(window).compactMap { axValue($0, "accessibilityIdentifier") as? String }
            XCTFail("Missing crop rotation controls: \(ids.filter { $0.contains("crop") })")
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                if let data = bitmap.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: "output/tools/diagnostics/crop-rotation-failure.png"))
                }
            }
            throw error
        }
        editing.completeDevelopmentCrop(context: try XCTUnwrap(editing.developmentContext))
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            let ids = accessibleElements(window).compactMap { axValue($0, "accessibilityIdentifier") as? String }
            return !editing.cropEditing && ids.contains("photos.curves.section")
                && !ids.contains("photos.whiteBalance.section")
                && !ids.contains("photos.crop.cancel") && !ids.contains("photos.crop.done")
        }
        await editing.shutdown()
    }

    private func viewTree(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(viewTree)
    }

    @MainActor func testColorTrackUsesRealNSSliderAndPreservesNativeAction() throws {
        var changes: [Double] = []
        let sliderView = PhotosNativeSlider(value: 0, range: -1...1,
            trackColors: [.blue, .gray, .yellow], onChange: { changes.append($0) }, onEditing: { _ in })
            .frame(width: 240, height: 26)
        let host = NSHostingView(rootView: sliderView)
        host.frame = .init(x: 0, y: 0, width: 240, height: 26); host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.minValue, -1); XCTAssertEqual(slider.maxValue, 1)
        slider.doubleValue = 0.4
        XCTAssertEqual(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider), true)
        XCTAssertEqual(changes, [0.4])
    }
}
