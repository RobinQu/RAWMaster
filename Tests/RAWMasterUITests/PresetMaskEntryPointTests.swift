import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

@MainActor final class PresetMaskEntryPointTests: XCTestCase {
    private func attribute(_ object: NSObject, _ name: String) -> Any? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func element(_ id: String, in window: NSWindow) -> NSObject? {
        var nodes: [NSObject] = [window]
        var seen = Set<ObjectIdentifier>()
        while let node = nodes.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            if attribute(node, "accessibilityIdentifier") as? String == id { return node }
            nodes += attribute(node, "accessibilityChildren") as? [NSObject] ?? []
        }
        return nil
    }

    private func eventually(_ message: String, _ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < limit {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail(message)
        throw NSError(domain: "PresetMaskEntryPointTests", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: message])
    }

    private func textField(in view: NSView) -> NSTextField? {
        if let input = view as? NSTextField, input.isEditable { return input }
        return view.subviews.lazy.compactMap { self.textField(in: $0) }.first
    }

    private func press(_ id: String, in window: NSWindow) throws {
        let row = try XCTUnwrap(element(id, in: window), id)
        let action = NSSelectorFromString("accessibilityPerformPress")
        XCTAssertTrue(row.responds(to: action))
        _ = row.perform(action)
    }

    private func choose(_ mode: EditingFilterBrowserMode, in window: NSWindow) throws {
        let id = "editing.filters.browserMode." + mode.rawValue
        let press = NSSelectorFromString("accessibilityPerformPress")
        var nodes = [element("editing.filters.browserMode", in: window) ?? window]
        var seen = Set<ObjectIdentifier>()
        while let node = nodes.popLast() {
            guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
            let matches = attribute(node, "accessibilityIdentifier") as? String == id
                || ["accessibilityLabel","accessibilityTitle","accessibilityDescription"].contains { attribute(node, $0) as? String == mode.title }
            if matches, node.responds(to: press) { _ = node.perform(press); return }
            nodes += attribute(node, "accessibilityChildren") as? [NSObject] ?? []
        }
        // AppKit also exposes the segmented picker through its native target/action on some releases.
        var views = [try XCTUnwrap(window.contentView)]
        while let view = views.popLast() {
            if let control = view as? NSSegmentedControl,
               let index = (0..<control.segmentCount).first(where: { control.label(forSegment: $0) == mode.title }),
               let action = control.action {
                control.selectedSegment = index
                XCTAssertTrue(control.sendAction(action, to: control.target))
                return
            }
            views += view.subviews
        }
        XCTFail("Missing filter browser option " + mode.title)
    }

    private func search(_ query: String, field: NSTextField, window: NSWindow) throws {
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(window.fieldEditor(false, for: field) as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(query, replacementRange: editor.selectedRange())
    }

    func testSearchFindsAndAppliesPresetInWindowAlongsideMaskControls() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture()
        defer { fixture.clean() }
        fixture.defaults.set(EditingFilterBrowserMode.catalog.rawValue, forKey: EditingFilterBrowserMode.defaultsKey)
        let backend = PhotosDevelopmentBackend()
        let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults, editingPreviewBackend: backend)
        app.selectScope(.project, id: fixture.assets[0].projectID)
        app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
        let editing = try XCTUnwrap(app.editing)
        try await eventually("The normal editor did not open") {
            if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
            return editing.developmentContext != nil
        }
        let context = try XCTUnwrap(editing.developmentContext)
        let session = editing.developmentSession
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appendingPathComponent("test-presets"))
        var patch = DevelopmentPresetPatch()
        patch.exposure = 0.375
        var records = (0..<1075).map { i in
            DevelopmentPresetRecord(id: "sample-\(i)", name: "样片预设 \(i)", group: "组 \(i/25)",
                                    kind: .user, patch: patch)
        }
        var savedParameters = session.parameters
        savedParameters.light.enabled = true
        savedParameters.light.exposure = 0.625
        let full = try DevelopmentPresetPatch(fullRecipe: .init(adjustmentsV3: savedParameters),
                                              sourceID: XCTUnwrap(session.source?.sourceContentID))
        records[0] = .init(id: "full", name: "整图还原", group: "单张", kind: .user, patch: full)
        _ = try catalog.importBatch(records, originals: [:])
        let host = NSHostingView(rootView: HStack {
            EditingLeftSidebar(editing: editing, presetCatalog: catalog)
            ScrollView { PhotosMaskControls(editing: editing, session: session, context: context) }
        }.frame(width: 780, height: 880))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 880),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.orderBack(nil)
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        try await eventually("Preset search and mask tools must be reachable in the window") {
            ["editing.presets.search", "editing.presets.create", "photos.mask.subject", "photos.mask.brush"].allSatisfy {
                self.element($0, in: window) != nil
            }
        }
        let initialHistory = session.history.entryCount
        let field = try XCTUnwrap(textField(in: host))
        try search("样片预设 1074", field: field, window: window)
        try await eventually("Searching the mounted catalog must expose the final record") {
            self.element("editing.preset.sample-1074", in: window) != nil
        }
        XCTAssertNil(element("editing.preset.sample-1073", in: window))
        XCTAssertEqual(session.history.entryCount, initialHistory)
        try press("editing.preset.sample-1074", in: window)
        try await eventually("The accessible row must use the editing transaction") {
            session.parameters.light.exposure == 0.375 && session.history.entryCount == initialHistory + 1
        }
        let beforeFull = session.recipe
        try search("整图还原", field: field, window: window)
        try await eventually("Full recipe must be searchable") { self.element("editing.preset.full", in: window) != nil }
        try press("editing.preset.full", in: window)
        try await eventually("Selecting a full recipe must expose preview and adopt independently") {
            self.element("editing.presets.previewFull", in: window) != nil && self.element("editing.presets.adoptFull", in: window) != nil
        }
        XCTAssertEqual(session.recipe, beforeFull)
        try press("editing.presets.previewFull", in: window)
        try await eventually("Explicit full preview should own the temporary canvas") { editing.hoveredPresetID == "full" }
        XCTAssertEqual(session.recipe, beforeFull)
        try press("editing.presets.previewFull", in: window)
        try await eventually("Ending preview should restore the committed recipe") { editing.hoveredPresetID == nil }
        XCTAssertEqual(session.history.entryCount, initialHistory + 1)
        try press("editing.presets.adoptFull", in: window)
        try await eventually("Only explicit adoption should replace a full recipe") {
            session.parameters.light.exposure == 0.625 && session.history.entryCount == initialHistory + 2
        }
        try session.undo(context: context)
        XCTAssertEqual(session.recipe, beforeFull)
        let requests = await backend.thumbnailRequests
        XCTAssertFalse(requests.contains { $0.kind == .filters }, "Browsing, filtering and adopting must not request filter tiles")
    }

    func testClassicAndCatalogSwitchInWindowRestoresPreferenceAndCancelsDrafts() async throws {
        _ = NSApplication.shared
        let ax = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let old = NSApp.accessibilityAttributeValue(ax)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: ax)
        defer { NSApp.accessibilitySetValue(old, forAttribute: ax) }
        let fixture = try EditingWorkflowTests.Fixture(); defer { fixture.clean() }
        let catalog = DevelopmentPresetCatalog(root: fixture.root.appending(path: "switch-presets"))
        var patch = DevelopmentPresetPatch()
        patch.semanticMasks = [try DevelopmentPresetMaskIntent(target: .subject, name: "主体", adjustments: .init(exposure: 0.4))]
        let record = DevelopmentPresetRecord(id: "fixture-subject", name: "人物选区", group: "个人预设", kind: .user, patch: patch)
        var exposure = DevelopmentPresetPatch()
        exposure.exposure = 0.3
        let hoverRecord = DevelopmentPresetRecord(id: "fixture-light", name: "提亮", group: "个人预设", kind: .user, patch: exposure)
        _ = try catalog.importBatch([record, hoverRecord], originals: [:])
        func openEditor() async throws -> (app: AppModel, editing: EditingController, context: EditingInteractionContext) {
            let app = AppModel(libraryURL: fixture.library, defaults: fixture.defaults,
                               editingPreviewBackend: PhotosDevelopmentBackend(filtersEnabled: true))
            app.selectScope(.project, id: fixture.assets[0].projectID)
            app.select(fixture.assets[0]); app.setMode(.single); app.openNativeEditing()
            let editing = try XCTUnwrap(app.editing)
            try await eventually("Opening editor with filter capability") {
                if editing.work != nil, editing.developmentContext == nil { editing.beginDevelopmentInterface() }
                return editing.developmentContext != nil && editing.availableDevelopmentFilters.contains(.vivid)
            }
            return (app, editing, try XCTUnwrap(editing.developmentContext))
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 850), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        func mount(_ editing: EditingController, _ context: EditingInteractionContext) {
            let host = NSHostingView(rootView: HStack {
                EditingLeftSidebar(editing: editing, presetCatalog: catalog)
                ScrollView { PhotosMaskControls(editing: editing, session: editing.developmentSession, context: context) }
            }.frame(width: 780, height: 850))
            window.contentView = host; window.orderBack(nil); host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        }
        XCTAssertNil(fixture.defaults.string(forKey: EditingFilterBrowserMode.defaultsKey))
        let first = try await openEditor(), editing = first.editing
        let initial = editing.recipe, history = editing.developmentSession.history.entryCount
        let entered = expectation(description: "Semantic preparation entered")
        let cancelled = expectation(description: "Leaving catalog cancelled its model task")
        editing.developmentMaskInput = EditingMaskInputSession(editing: editing, generate: { _,_,_,_ in
            entered.fulfill()
            do { try await Task.sleep(for: .seconds(30)); throw CancellationError() }
            catch { if Task.isCancelled { cancelled.fulfill() }; throw error }
        })
        mount(editing, first.context)
        try await eventually("First launch must mount classic filter controls") {
            self.element("editing.filters.reset", in: window) != nil && self.element("editing.filter.favorite.vivid", in: window) != nil
        }
        XCTAssertNil(element("editing.presets.search", in: window))
        try press("editing.filter.favorite.vivid", in: window)
        XCTAssertTrue(editing.favoriteDevelopmentFilters.contains(.vivid))
        editing.developmentMaskInput.select(.linear, context: first.context)
        XCTAssertEqual(editing.developmentMaskInput.activeKind, .linear)
        editing.previewDevelopmentFilter(.vivid, context: first.context)
        XCTAssertNotNil(editing.hoveredPresetID)
        try choose(.catalog, in: window)
        try await eventually("Catalog must replace the classic grid, clear its hover and retain the right-hand mask controls") {
            self.element("editing.presets.search", in: window) != nil && self.element("editing.filters.reset", in: window) == nil
                && self.element("photos.mask.subject", in: window) != nil && editing.hoveredPresetID == nil
        }
        XCTAssertEqual(fixture.defaults.string(forKey: EditingFilterBrowserMode.defaultsKey), EditingFilterBrowserMode.catalog.rawValue)
        try await eventually("The catalog must load the previously favorited classic filter") { self.element("editing.filter.favorite.vivid", in: window) != nil }
        try press("editing.filter.favorite.vivid", in: window)
        XCTAssertFalse(editing.favoriteDevelopmentFilters.contains(.vivid))
        let host = try XCTUnwrap(window.contentView)
        let field = try XCTUnwrap(textField(in: host))
        try search(record.name, field: field, window: window)
        try await eventually("The semantic preset is searchable") { self.element("editing.preset.fixture-subject", in: window) != nil }
        try press("editing.preset.fixture-subject", in: window)
        try await eventually("Semantic selection requires an explicit preparation") { self.element("editing.presets.prepareMasks", in: window) != nil }
        try press("editing.presets.prepareMasks", in: window)
        await fulfillment(of: [entered], timeout: 3)
        editing.previewDevelopmentPreset(hoverRecord, context: first.context)
        XCTAssertEqual(editing.hoveredPresetID, hoverRecord.id)
        try choose(.classic, in: window)
        await fulfillment(of: [cancelled], timeout: 3)
        try await eventually("Classic entry restores its controls") {
            self.element("editing.filters.reset", in: window) != nil && self.element("editing.presets.search", in: window) == nil
        }
        XCTAssertEqual(fixture.defaults.string(forKey: EditingFilterBrowserMode.defaultsKey), EditingFilterBrowserMode.classic.rawValue)
        XCTAssertEqual(editing.recipe, initial); XCTAssertEqual(editing.developmentSession.history.entryCount, history)
        XCTAssertNil(editing.hoveredPresetID)
        XCTAssertEqual(editing.developmentMaskInput.activeKind, .linear)
        XCTAssertTrue(editing.developmentSession.parameters.masks.isEmpty)
        try choose(.catalog, in: window)
        try await eventually("The selected directory preference must persist before closing") {
            fixture.defaults.string(forKey: EditingFilterBrowserMode.defaultsKey) == EditingFilterBrowserMode.catalog.rawValue
        }
        window.contentView = nil; await editing.shutdown(finishPreviews: false)
        let reopened = try await openEditor()
        mount(reopened.editing, reopened.context)
        try await eventually("A fresh editor must open the explicitly selected catalog") {
            self.element("editing.presets.search", in: window) != nil && self.element("editing.filters.reset", in: window) == nil
        }
        XCTAssertFalse(reopened.editing.favoriteDevelopmentFilters.contains(.vivid))
        XCTAssertEqual(reopened.editing.recipe, initial)
        XCTAssertNil(reopened.editing.hoveredPresetID)
        window.contentView = nil; await reopened.editing.shutdown(finishPreviews: false)
    }
}
