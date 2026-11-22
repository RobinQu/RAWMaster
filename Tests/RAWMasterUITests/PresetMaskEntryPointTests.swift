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
}
