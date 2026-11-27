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

    @MainActor func testEditingLayoutUsesCanvasNavigationWithoutFilmstrip() async throws {
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }

        let fixture = try EditingWorkflowTests.Fixture(photoCount: 3); defer { fixture.clean() }
        try fixture.store.createGroup(ids: fixture.assets.prefix(2).map(\.id), name: "两张测试组", kind: "连拍")
        let model = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
            editingPreviewBackend: PhotosDevelopmentBackend())
        model.selectScope(.project, id: fixture.assets[0].projectID)
        let photos = model.browserAssets.map(\.id)
        XCTAssertEqual(photos.count, 3)
        model.select(try XCTUnwrap(model.browserAssets.first)); model.setMode(.single); model.openNativeEditing()
        let editing = try XCTUnwrap(model.editing)
        addTeardownBlock { await editing.shutdown() }
        try await wait { editing.work != nil && editing.preview != nil }

        let host = NSHostingView(rootView: WorkbenchView().environmentObject(model)
            .environment(\.colorScheme, .dark).frame(width: 1440, height: 900))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
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
                return ids.contains("editing.darkroom") && ids.contains("editing.leftRail.filters")
                    && ids.contains("editing.previousPhoto") && ids.contains("editing.nextPhoto")
                    && ids.contains("editing.beforeAfter") && ids.contains("editing.crop")
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
        func element(_ identifier: String) -> NSObject? {
            accessibleElements(window).first { axValue($0, "accessibilityIdentifier") as? String == identifier }
        }
        XCTAssertNil(element("editing.filmstrip"))
        XCTAssertNil(element("browser.filmstrip"))
        func button(_ label: String) -> NSObject? {
            accessibleElements(window).first { axValue($0, "accessibilityLabel") as? String == label
                && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) }
        }
        try press(try XCTUnwrap(button("矢量示波器")))
        try await wait { element("photos.scopes.vectorscope") != nil }
        host.layoutSubtreeIfNeeded()
        let vector = try XCTUnwrap(element("photos.scopes.vectorscope"))
        if vector.responds(to: NSSelectorFromString("accessibilityFrame")) {
            let frame = try XCTUnwrap(vector.value(forKey: "accessibilityFrame") as? NSValue).rectValue
            XCTAssertEqual(frame.height, 96, accuracy: 1)
        } else { XCTFail("Vectorscope must expose its plot bounds") }
        try press(try XCTUnwrap(button("直方图")))
        try await wait { element("photos.scopes.vectorscope") == nil }
        host.layoutSubtreeIfNeeded()
        let histogram = try XCTUnwrap(element("photos.scopes.histogram.plot"))
        let histogramFrame = try XCTUnwrap(histogram.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        XCTAssertEqual(histogramFrame.height, 96, accuracy: 1)
        try await wait { editing.developmentContext != nil }
        let beforeSampling = editing.recipe, samplingHistory = editing.developmentSession.history.entryCount
        for x in [0.2, 0.5, 0.8] { XCTAssertTrue(editing.colorSamplers.place(.init(x: x, y: 0.5))) }
        try await wait { host.layoutSubtreeIfNeeded(); return element("photos.scopes.sampler.row.3") != nil }
        XCTAssertEqual(editing.recipe, beforeSampling)
        XCTAssertEqual(editing.developmentSession.history.entryCount, samplingHistory)
        capture(host, variable: "RAWMASTER_CAPTURE_TEXT_SAMPLERS_WORKBENCH")
        try press(try XCTUnwrap(element("photos.tool.蒙版")))
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return element("photos.mask.empty") != nil && element("photos.mask.create") != nil
        }
        try press(try XCTUnwrap(element("photos.mask.create")))
        try await wait { element("photos.mask.radial") != nil }
        capture(host, variable: "RAWMASTER_CAPTURE_MASK_TOOLS")
        let maskContext = try XCTUnwrap(editing.developmentContext)
        try press(try XCTUnwrap(element("photos.mask.radial")))
        try await wait { editing.developmentMaskInput.activeKind == .radial && element("photos.mask.drawing") != nil }
        try press(try XCTUnwrap(button("取消")))
        XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        try press(try XCTUnwrap(element("photos.mask.create")))
        try await wait { element("photos.mask.range") != nil }
        try press(try XCTUnwrap(element("photos.mask.range")))
        let layer = try XCTUnwrap(editing.developmentSession.parameters.masks.last)
        try await wait { element("photos.mask.layer." + layer.id.uuidString) != nil && element("photos.mask.manage") != nil }
        XCTAssertEqual(editing.developmentScopeMaskID, layer.id)
        capture(host, variable: "RAWMASTER_CAPTURE_COMPACT_MASK")
        try press(try XCTUnwrap(element("photos.mask.layer.enabled." + layer.id.uuidString)))
        XCTAssertEqual(editing.developmentSession.parameters.masks.last?.enabled, false)
        try editing.developmentSession.undo(context: maskContext)
        XCTAssertEqual(editing.developmentSession.parameters.masks.last?.enabled, true)
        try editing.developmentSession.undo(context: maskContext)
        XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        try press(try XCTUnwrap(element("photos.tool.基础")))
        try await wait {
            editing.developmentSession.expandedGroups.contains(.whiteBalance) && element("photos.light.disclosure") != nil
        }
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        let balanceMenu = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSPopUpButton }.first {
            $0.accessibilityLabel() == "校正方式"
        })
        let menuFrame = window.convertToScreen(balanceMenu.convert(balanceMenu.bounds, to: nil))
        func actionFrame(_ identifier: String) throws -> NSRect {
            let action = try XCTUnwrap(element(identifier), "Missing \(identifier); white balance IDs: \(accessibleElements(window).compactMap { axValue($0, "accessibilityIdentifier") as? String }.filter { $0.contains("whiteBalance") })")
            return try XCTUnwrap(action.value(forKey: "accessibilityFrame") as? NSValue).rectValue
        }
        capture(host, variable: "RAWMASTER_CAPTURE_TEXT_SAMPLERS_AFTER_SWITCH")
        do {
            try await wait {
                if editing.developmentToolsPaused { editing.beginDevelopmentInterface() }
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                return editing.developmentContext != nil
                    && element("photos.whiteBalance.correction.heading") != nil
                    && element("photos.whiteBalance.refinement.heading") != nil
            }
        } catch {
            let nodes = accessibleElements(window)
            let balanceNodes = nodes.compactMap { node -> String? in
                let id = axValue(node, "accessibilityIdentifier") as? String ?? ""
                let label = axValue(node, "accessibilityLabel") as? String ?? ""
                let value = axValue(node, "accessibilityValue") as? String ?? ""
                guard id.contains("whiteBalance") || label == "校正方式" || label == "微调" else { return nil }
                return "\(id): \(label) / \(value)"
            }
            XCTFail("White balance measurement unavailable: nodes=\(nodes.count), context=\(editing.developmentContext != nil), paused=\(editing.developmentToolsPaused), ready=\(editing.sourceReady), stage=\(editing.stage), balance=\(balanceNodes)")
            throw error
        }
        let correctionHeading = try actionFrame("photos.whiteBalance.correction.heading")
        XCTAssertEqual(correctionHeading.minY - menuFrame.maxY, 7, accuracy: 1)
        let appliedFrame = try actionFrame("photos.whiteBalance.applied"), refinementHeading = try actionFrame("photos.whiteBalance.refinement.heading")
        XCTAssertEqual(appliedFrame.minY - refinementHeading.maxY, 16, accuracy: 1)
        let samplerAdd = try actionFrame("photos.scopes.sampler.add"), samplerRow = try actionFrame("photos.scopes.sampler.row.1")
        XCTAssertEqual(samplerAdd.width, samplerRow.width, accuracy: 1)
        XCTAssertEqual(samplerRow.height, 32, accuracy: 1)
        let autoFrame = try actionFrame("photos.whiteBalance.auto")
        let originalFrame = try actionFrame("photos.whiteBalance.original")
        XCTAssertEqual(autoFrame.width, menuFrame.width, accuracy: 1)
        XCTAssertEqual(originalFrame.width, menuFrame.width, accuracy: 1)
        XCTAssertEqual(autoFrame.minX, menuFrame.minX, accuracy: 1)
        XCTAssertLessThan(originalFrame.maxY, autoFrame.minY, "Correction actions occupy separate rows")
        try press(try XCTUnwrap(element("photos.light.disclosure")))
        try await wait { element("photos.light.exposure") != nil && element("photos.light.exposure.number") != nil }
        capture(host, variable: "RAWMASTER_CAPTURE_COMPACT_BASIC")
        var context = try XCTUnwrap(editing.developmentContext)
        try press(try XCTUnwrap(element("editing.leftRail.filters")))
        _ = try editing.developmentSession.createSnapshot(name: "基底", context: context)
        let snapshot = try editing.developmentSession.createSnapshot(name: "复核", context: context)
        let snapshotID = "editing.snapshot." + snapshot.id.uuidString
        try await wait {
            host.layoutSubtreeIfNeeded()
            return element(snapshotID) != nil
        }
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        try await wait { editing.developmentContext == nil && element(snapshotID) != nil }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        try await wait { editing.developmentContext != nil }
        context = try XCTUnwrap(editing.developmentContext)

        if ProcessInfo.processInfo.environment["RAWMASTER_CAPTURE_LAYOUT"] == "1",
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let data = bitmap.representation(using: .png, properties: [:]) {
                try? data.write(to: URL(fileURLWithPath: "output/tools/diagnostics/darkroom-layout-current.png"))
            }
        }

        try press(try XCTUnwrap(element("photos.tool.分级")))
        try await wait {
            editing.developmentSession.expandedSections.contains("grading") && element("photos.grading.enabled") != nil
        }
        try editing.updateDevelopmentLegacy(context: context, control: "test.grading") { basis in
            var color = basis.color ?? .init()
            color.grading.global.saturation = 30
            basis.color = color
        }
        let gradeToggle = try XCTUnwrap(element("photos.grading.enabled"))
        try press(gradeToggle)
        try await wait { editing.developmentLegacyBasis.color?.grading.isEnabled == false }
        XCTAssertEqual(editing.developmentLegacyBasis.color?.grading.global.saturation, 30)
        try press(try XCTUnwrap(element("photos.grading.enabled")))
        XCTAssertEqual(editing.developmentLegacyBasis.color?.grading.isEnabled, true)
        try press(try XCTUnwrap(element("photos.tool.基础")))
        try await wait { element("photos.light.exposure") != nil }

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
        try press(try XCTUnwrap(element("editing.nextPhoto")))
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return editing.asset?.id == photos[1] && element("editing.previousPhoto") != nil
        }
        try press(try XCTUnwrap(element("editing.previousPhoto")))
        try await wait { editing.asset?.id == photos[0] }
        model.activateWorkflow(.library)
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return element("browser.filmstrip") != nil && element("editing.darkroom") == nil
        }
        XCTAssertEqual(model.focusedID, photos[0])
        await editing.shutdown()
    }

    @MainActor private func capture(_ host: NSView, variable: String) {
        guard let path = ProcessInfo.processInfo.environment[variable] else { return }
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        host.effectiveAppearance.performAsCurrentDrawingAppearance {
            guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    private func viewTree(_ root: NSView) -> [NSView] {
        [root] + root.subviews.flatMap(viewTree)
    }

    @MainActor func testFilterHeaderActionsStayAlignedIndependentAndRecipeScoped() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture(photoCount: 1)
        defer { fixture.clean() }
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: PhotosDevelopmentBackend(filtersEnabled: true))
        app.selectScope(.project, id: fixture.assets[0].projectID)
        app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        addTeardownBlock { await editing.shutdown() }
        try await wait {
            if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil && editing.availableDevelopmentFilters.contains(.vivid)
        }
        let session = editing.developmentSession, context = try XCTUnwrap(editing.developmentContext)
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appendingPathComponent("header-presets"))
        let chosen = try XCTUnwrap(editing.availableDevelopmentFilters.first { $0 != .original && !$0.isSpektrafilm })
        var light = session.parameters.light
        light.exposure = 0.375
        try session.apply(.setParameters(.light(light)), event: .init(context: context, control: .init(group: .light, name: "测试光效")))
        for scheme in [ColorScheme.dark, .light] {
            let host = NSHostingView(rootView: EditingLeftSidebar(editing: editing, presetCatalog: catalog)
                .environment(\.colorScheme, scheme).frame(width: EditingLayout.sidebarWidth, height: 700))
            let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.setContentSize(.init(width: EditingLayout.sidebarWidth, height: 700))
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
            defer { window.orderOut(nil); window.contentView = nil; window.close() }
            func element(_ id: String) -> NSObject? {
                accessibleElements(window).first { axValue($0, "accessibilityIdentifier") as? String == id }
            }
            let ids = ["editing.leftRail.filters", "editing.filters.reset", "editing.filters.enabled", "editing.presets.create", "editing.presets.options"]
            try await wait { host.layoutSubtreeIfNeeded(); return ids.allSatisfy { element($0) != nil } }
            let frames = try ids.map { id in
                try XCTUnwrap(try XCTUnwrap(element(id)).value(forKey: "accessibilityFrame") as? NSValue).rectValue
            }
            for index in 1..<frames.count {
                XCTAssertGreaterThanOrEqual(frames[index].minX, frames[index - 1].maxX - 1)
                XCTAssertEqual(frames[index].midY, frames[0].midY, accuracy: 1)
                XCTAssertGreaterThanOrEqual(frames[index].height, 26, "\(ids[index]) frame: \(frames[index])")
            }
            XCTAssertNil(element("editing.presets.import"), "Only the merged menu remains")
            XCTAssertEqual(accessibleElements(window).filter { axValue($0, "accessibilityIdentifier") as? String == "editing.presets.create" }.count, 1)
            XCTAssertEqual(element("editing.filters.enabled")?.value(forKey: "accessibilityEnabled") as? NSNumber, NSNumber(value: false))
            XCTAssertEqual(element("editing.filters.reset")?.value(forKey: "accessibilityEnabled") as? NSNumber, NSNumber(value: false))
            var filter = session.parameters.filter
            filter.selection = chosen; filter.intensity = 52; filter.enabled = true
            try session.apply(.setParameters(.filter(filter)), event: .init(context: context, control: .init(group: .filter, name: "测试滤镜")))
            try await wait { element("editing.filters.enabled")?.value(forKey: "accessibilityEnabled") as? NSNumber == NSNumber(value: true) }
            let adopted = session.parameters, before = session.history.entryCount
            try press(try XCTUnwrap(element("editing.filters.enabled")))
            XCTAssertFalse(session.parameters.filter.enabled)
            XCTAssertEqual(session.parameters.filter.selection, chosen); XCTAssertEqual(session.parameters.filter.intensity, 52)
            XCTAssertEqual(session.parameters.light, adopted.light); XCTAssertEqual(session.history.entryCount, before + 1)
            try press(try XCTUnwrap(element("editing.leftRail.filters")))
            try await wait { host.layoutSubtreeIfNeeded(); return element("editing.presets.search") == nil }
            try press(try XCTUnwrap(element("editing.filters.enabled")))
            XCTAssertTrue(session.parameters.filter.enabled)
            XCTAssertNil(element("editing.presets.search"), "Enabling does not expand the panel")
            try press(try XCTUnwrap(element("editing.filters.reset")))
            var expected = adopted; expected.filter = .init()
            XCTAssertEqual(session.parameters, expected, "Reset changes the filter, not the exposure or other groups")
            try session.undo(context: context)
            XCTAssertEqual(session.parameters, adopted)
            try press(try XCTUnwrap(element("editing.leftRail.filters")))
            try await wait { element("editing.presets.search") != nil }
            let recipe = session.recipe, history = session.history.entryCount, snapshot = try catalog.snapshot()
            try press(try XCTUnwrap(element("editing.presets.create")))
            try await wait { accessibleElements(window).contains { axValue($0, "accessibilityLabel") as? String == "取消" } }
            let cancel = try XCTUnwrap(accessibleElements(window).first {
                axValue($0, "accessibilityLabel") as? String == "取消" && $0.responds(to: NSSelectorFromString("accessibilityPerformPress"))
            })
            try press(cancel)
            try await wait { window.attachedSheet == nil }
            XCTAssertEqual(session.recipe, recipe); XCTAssertEqual(session.history.entryCount, history)
            XCTAssertEqual(try catalog.snapshot().records, snapshot.records)
            capture(host, variable: scheme == .dark ? "RAWMASTER_CAPTURE_FILTER_HEADER_DARK" : "RAWMASTER_CAPTURE_FILTER_HEADER_LIGHT")
            try session.apply(.reset(.filter), event: .init(context: context, control: .init(group: .filter, name: "结束测试滤镜")))
        }
        await editing.shutdown()
    }

    @MainActor func testFlatCheckboxKeepsToggleAccessibilityAndBinding() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        final class CheckboxState: ObservableObject {
            @Published var checked = false
            @Published var disabled = false
        }
        struct CheckboxContent: View {
            @ObservedObject var state: CheckboxState
            var body: some View {
                Toggle("RAW 细节", isOn: $state.checked).toggleStyle(PhotosFlatCheckboxStyle())
                    .disabled(state.disabled).frame(width: 230, height: 30)
            }
        }
        let state = CheckboxState()
        let host = NSHostingView(rootView: CheckboxContent(state: state))
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 230, height: 30),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.makeKeyAndOrderFront(nil)
        func checkbox() -> NSObject? {
            accessibleElements(window).first { axValue($0, "accessibilityLabel") as? String == "RAW 细节"
                && $0.responds(to: NSSelectorFromString("accessibilityPerformPress")) }
        }
        try await wait { host.layoutSubtreeIfNeeded(); return checkbox() != nil }
        XCTAssertEqual(axValue(try XCTUnwrap(checkbox()), "accessibilityRole") as? String, NSAccessibility.Role.checkBox.rawValue)
        try press(try XCTUnwrap(checkbox()))
        XCTAssertTrue(state.checked)
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return (axValue(checkbox() ?? host, "accessibilityValue") as? NSNumber)?.intValue == 1
        }
        try press(try XCTUnwrap(checkbox()))
        XCTAssertFalse(state.checked)
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            return (axValue(checkbox() ?? host, "accessibilityValue") as? NSNumber)?.intValue == 0
        }
        state.disabled = true
        try await wait {
            host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            guard let box = checkbox(), box.responds(to: NSSelectorFromString("isAccessibilityEnabled")) else { return false }
            return (box.value(forKey: "accessibilityEnabled") as? NSNumber)?.boolValue == false
        }
        XCTAssertFalse(state.checked)
    }

    @MainActor func testFlatCheckboxRendersAnOutlineWithoutReliefInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let background = Color(red: 0.3, green: 0.3, blue: 0.3)
            let renderer = ImageRenderer(content: Toggle("细节", isOn: .constant(false))
                .toggleStyle(PhotosFlatCheckboxStyle()).environment(\.colorScheme, scheme)
                .frame(width: 160, height: 26, alignment: .leading).background(background))
            renderer.scale = 1
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            let upper = try XCTUnwrap(bitmap.colorAt(x: 5, y: 9)?.usingColorSpace(.sRGB))
            let lower = try XCTUnwrap(bitmap.colorAt(x: 5, y: 17)?.usingColorSpace(.sRGB))
            let border = try XCTUnwrap(bitmap.colorAt(x: 0, y: 13)?.usingColorSpace(.sRGB))
            XCTAssertEqual(upper.redComponent, lower.redComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(upper.greenComponent, lower.greenComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(upper.blueComponent, lower.blueComponent, accuracy: 1.0 / 255)
            XCTAssertGreaterThan(abs(border.redComponent - upper.redComponent), 0.03, "The flat outline remains visible")
        }
    }

    @MainActor func testMaskToolIconsAreAvailableAndDistinct() throws {
        let kinds: [PhotosMaskToolIcon.Kind] = [.subject, .background, .instance, .brush, .linear, .radial, .range]
        var images = Set<Data>()
        for kind in kinds {
            if let symbol = kind.systemImage {
                XCTAssertNotNil(NSImage(systemSymbolName: symbol, accessibilityDescription: nil), symbol)
            }
            let renderer = ImageRenderer(content: PhotosMaskToolIcon(kind: kind).foregroundStyle(Color.white))
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            XCTAssertEqual(bitmap.pixelsWide, 36)
            images.insert(try XCTUnwrap(bitmap.representation(using: .png, properties: [:])))
        }
        XCTAssertEqual(images.count, kinds.count, "Each creation tool has a different visible shape")
        XCTAssertEqual(DevelopmentAdjustmentID.clarity.photosTitle, "清晰度")
    }

    @MainActor func testFlatMenuFillsRowAndUsesNativeSelection() throws {
        var selected = "RGB"
        let host = NSHostingView(rootView: PhotosFlatMenu(title: "曲线通道",
            selection: .init(get: { selected }, set: { selected = $0 }),
            options: ["RGB", "红色", "绿色", "蓝色"], label: { $0 }).frame(width: 230))
        host.frame = .init(x: 0, y: 0, width: 230, height: 26); host.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSPopUpButton }.first)
        XCTAssertEqual(menu.frame.width, 230, accuracy: 1)
        XCTAssertEqual(menu.frame.height, PhotosControlLayout.height)
        XCTAssertEqual(menu.titleOfSelectedItem, "RGB")
        menu.selectItem(at: 1)
        XCTAssertTrue(menu.sendAction(menu.action, to: menu.target))
        XCTAssertEqual(selected, "红色")
    }

    @MainActor func testAdjustmentSectionKeepsTightSymmetricTrackInsets() throws {
        let section = PhotosAdjustmentSection(id: .light, expanded: true, enabled: true, modified: false,
            onExpand: {}, onEnable: { _ in }, onReset: {}) {
                PhotosSliderRow(title: "曝光", value: .constant(0), range: -1...1, onChange: { _ in })
            }
        let host = NSHostingView(rootView: section.frame(width: 240))
        host.frame = .init(x: 0, y: 0, width: 240, height: 80)
        host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSSlider }.first)
        let track = slider.convert(slider.focusRingMaskBounds, to: host)
        XCTAssertEqual(track.minX, 12, accuracy: 0.5)
        XCTAssertEqual(host.bounds.maxX - track.maxX, 12, accuracy: 0.5)
    }

    @MainActor func testRailTooltipRendersItsArrowLeftOfTheEntireButton() throws {
        let icon = Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 32, height: 32)
            .overlay(alignment: .leading) { PhotosRailTooltip(title: "混色") }
        let content = icon.frame(width: 160, height: 40, alignment: .trailing)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        func alpha(_ x: Int, _ y: Int) -> CGFloat { bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0 }
        XCTAssertEqual(bitmap.pixelsWide, 160)
        XCTAssertGreaterThan(alpha(106, 20), 0.85, "Bubble is visible outside the button")
        XCTAssertGreaterThan(alpha(122, 20), 0.8, "Arrow extends towards the button")
        XCTAssertLessThan(alpha(122, 12), 0.4, "Only the arrow reaches this far right")
        XCTAssertLessThan(alpha(127, 20), 0.4, "There is space between arrow and button")
        let bareButton = Rectangle().fill(Color(red: 1, green: 0, blue: 0)).frame(width: 32, height: 32)
            .frame(width: 160, height: 40, alignment: .trailing)
        let baselineRenderer = ImageRenderer(content: bareButton)
        baselineRenderer.scale = 1
        let baseline = NSBitmapImageRep(cgImage: try XCTUnwrap(baselineRenderer.cgImage))
        for x in [130, 133, 140, 150] {
            let expected = try XCTUnwrap(baseline.colorAt(x: x, y: 20)?.usingColorSpace(.sRGB))
            let actual = try XCTUnwrap(bitmap.colorAt(x: x, y: 20)?.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.greenComponent, expected.greenComponent, accuracy: 1.0 / 255)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 1.0 / 255)
        }
    }

    @MainActor func testColorTrackUsesRealNSSliderAndPreservesNativeAction() throws {
        var changes: [Double] = [], edges: [Bool] = [], resetCount = 0
        let sliderView = PhotosSliderRow(title: "色调", value: .constant(0), range: -1...1,
            trackColors: [.blue, .gray, .yellow], onReset: { _ in resetCount += 1 },
            onEditing: { edges.append($0) }, onChange: { changes.append($0) })
            .frame(width: 240)
        let host = NSHostingView(rootView: sliderView)
        host.frame = .init(x: 0, y: 0, width: 240, height: 32); host.layoutSubtreeIfNeeded()
        let slider = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSSlider }.first)
        let number = try XCTUnwrap(viewTree(host).compactMap { $0 as? NSTextField }.first)
        XCTAssertEqual(slider.minValue, -1); XCTAssertEqual(slider.maxValue, 1)
        let track = slider.convert(slider.focusRingMaskBounds, to: host), field = number.convert(number.bounds, to: host)
        XCTAssertGreaterThanOrEqual(track.width, 230)
        XCTAssertEqual(track.height, PhotosControlLayout.height)
        XCTAssertEqual(slider.bounds.height - track.height, PhotosControlLayout.scaleHeight)
        XCTAssertEqual(track.midY, field.midY, accuracy: 1)
        XCTAssertGreaterThan(field.minX, track.midX)
        slider.doubleValue = 0.4
        XCTAssertEqual(NSApp.sendAction(try XCTUnwrap(slider.action), to: slider.target, from: slider), true)
        XCTAssertEqual(changes, [0.4])
        changes.removeAll()

        let sliderTrack = slider.focusRingMaskBounds
        var mouseY = slider.convert(.init(x: 0, y: sliderTrack.midY), to: nil).y
        func mouse(_ type: NSEvent.EventType, x: CGFloat, clicks: Int = 1) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: .init(x: x, y: mouseY),
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: clicks, pressure: 1))
        }
        slider.mouseDown(with: try mouse(.leftMouseDown, x: 16))
        slider.mouseUp(with: try mouse(.leftMouseUp, x: 16))
        XCTAssertTrue(changes.isEmpty); XCTAssertTrue(edges.isEmpty)
        slider.mouseDown(with: try mouse(.leftMouseDown, x: 16))
        slider.mouseDragged(with: try mouse(.leftMouseDragged, x: 36))
        slider.mouseDragged(with: try mouse(.leftMouseDragged, x: 56))
        slider.mouseUp(with: try mouse(.leftMouseUp, x: 56))
        XCTAssertEqual(edges, [true, false])
        XCTAssertEqual(changes.count, 2)
        XCTAssertEqual(try XCTUnwrap(changes.last), 0.8, accuracy: 1e-12)
        slider.mouseDown(with: try mouse(.leftMouseDown, x: 16, clicks: 2))
        slider.mouseUp(with: try mouse(.leftMouseUp, x: 16, clicks: 2))
        XCTAssertEqual(resetCount, 1)
        XCTAssertEqual(changes.count, 2)
        mouseY = slider.convert(.init(x: 0, y: slider.isFlipped ? sliderTrack.maxY + 2 : sliderTrack.minY - 2), to: nil).y
        slider.mouseDown(with: try mouse(.leftMouseDown, x: 16, clicks: 2))
        slider.mouseUp(with: try mouse(.leftMouseUp, x: 16, clicks: 2))
        XCTAssertEqual(resetCount, 1, "The ruler is decorative, not another input target")
    }
}
