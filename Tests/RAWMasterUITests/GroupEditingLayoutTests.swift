import AppKit
import SwiftUI
import XCTest
import RAWMasterCore
@testable import RAWMaster

final class GroupEditingLayoutTests: XCTestCase {
    @MainActor func testCatalogEditControlReceivesNativeHitAndOpensPropertiesWithReturnContext() async throws {
        _ = NSApplication.shared
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previousAXValue = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previousAXValue, forAttribute: enhancedUI) }
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        _ = try await f.populate("PropertiesEntry")
        let ids = try f.store.loadAssets().map(\.id)
        try f.store.createGroup(ids: ids, name: "目录组属性", kind: "延时")
        let group = try XCTUnwrap(try f.store.loadGroups().first)
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        model.openSequenceCatalog()
        let host = NSHostingView(rootView: LibraryCatalogView().environmentObject(model))
        let window = hostWindow(host, size: NSSize(width: 950, height: 620))
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 40_000_000)
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(descendants(host).compactMap { $0 as? NSButton }
            .first { $0.identifier?.rawValue == "group.catalog.properties." + group.id })
        XCTAssertTrue(button.isEnabled)
        XCTAssertEqual(button.accessibilityLabel(), "编辑拍摄组属性")
        let axNodes = accessibilityNodes(window)
        XCTAssertTrue(button.isAccessibilityElement())
        XCTAssertEqual(button.accessibilityRole(), .button)
        let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: host)
        let hit = host.hitTest(host.convert(point, to: host.superview))
        print("Catalog edit native hit:", String(describing: hit), "button", button.frame, "bounds", button.bounds, "point", point, "host", host.frame, "visible", window.isVisible, "AX", button.isAccessibilityElement())
        XCTAssertTrue(hit === button || hit?.isDescendant(of: button) == true, "Whole-card native input must not swallow the edit control")
        let exposed = try XCTUnwrap(axNodes.first { (axValue($0, key: "accessibilityLabel") as? String) == "编辑拍摄组属性"
            && (axValue($0, key: "accessibilityRole") as? String) == NSAccessibility.Role.button.rawValue } as? NSButton,
            "The edit control must be reachable from the window's public accessibilityChildren tree")
        let accepted = exposed.accessibilityPerformPress()
        XCTAssertTrue(accepted, "The exposed edit control must accept AX press")
        print("Catalog edit AX press returned", accepted, "opened properties", model.showGroups)
        XCTAssertEqual(model.scope, .group); XCTAssertEqual(model.scopeID, group.id)
        XCTAssertEqual(model.groupEditingID, group.id); XCTAssertTrue(model.showGroups)
        XCTAssertTrue(model.canReturnToCatalog); XCTAssertEqual(model.catalogParentTitle, "拍摄序列")
    }

    @MainActor func testNativeCardInputExcludesOnlyItsTopTrailingEditArea() {
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 220))
        let input = CatalogCardInput.InputView(frame: parent.bounds)
        parent.addSubview(input); input.excludesEditButton = true
        XCTAssertTrue(input.isEditButtonPoint(NSPoint(x: 270, y: 210)))
        XCTAssertFalse(input.isEditButtonPoint(NSPoint(x: 200, y: 210)))
        XCTAssertFalse(input.isEditButtonPoint(NSPoint(x: 270, y: 100)))
        XCTAssertNil(input.hitTest(NSPoint(x: 270, y: 210)))
        input.excludesEditButton = false
        XCTAssertFalse(input.isEditButtonPoint(NSPoint(x: 270, y: 210)))
    }

    @MainActor func testOptionalGroupEditingCaptures() async throws {
        guard let path = ProcessInfo.processInfo.environment["RAWMASTER_GROUP_EDITING_CAPTURE_OUTPUT"] else {
            throw XCTSkip("Set RAWMASTER_GROUP_EDITING_CAPTURE_OUTPUT for native create/edit/actions/catalog/header captures")
        }
        _ = NSApplication.shared
        let output = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let f = try ProjectReviewUITests.Fixture(); defer { f.clean() }
        let session = try await f.populate("GroupEditingScreens", filenames: (1...6).map { "\($0).jpg" })
        let ids = try f.store.loadAssets().map(\.id)
        try f.store.createGroup(ids: Array(ids.prefix(4)), name: "山谷日落延时", kind: "延时")
        try f.store.createGroup(ids: Array(ids.suffix(2)), name: "后期校准组", kind: "自定义校准")
        let model = AppModel(libraryURL: f.library, defaults: f.defaults)
        let group = try XCTUnwrap(model.groups.first { $0.name == "山谷日落延时" })
        for dark in [false, true] {
            model.selectScope(.project, id: session.projectID)
            model.selectedIDs = Set(ids.prefix(2)); model.editGroup()
            try await capture(GroupSheet().environmentObject(model), size: NSSize(width: 760, height: 590), dark: dark,
                name: "create-" + (dark ? "dark" : "light"), output: output)
            model.showGroups = false
            model.selectScope(.group, id: group.id); model.editGroup(group.id)
            try await capture(GroupSheet().environmentObject(model), size: NSSize(width: 760, height: 630), dark: dark,
                name: "edit-" + (dark ? "dark" : "light"), output: output)
            model.showGroups = false
        }
        model.selectScope(.group, id: group.id); model.selectedIDs = Set(group.assetIDs.prefix(2))
        try await capture(GridSelectionActionBar().environmentObject(model), size: NSSize(width: 720, height: 150), dark: false, name: "group-selection-remove", output: output)
        model.selectedIDs = []; model.focusedID = nil
        try await capture(WorkbenchView().environmentObject(model), size: NSSize(width: 1100, height: 720), dark: false, name: "group-header-no-selection", output: output)
        model.openSequenceCatalog()
        try await capture(LibraryCatalogView().environmentObject(model), size: NSSize(width: 950, height: 620), dark: false, name: "catalog-properties", output: output)
    }

    @MainActor private func hostWindow<V: View>(_ host: NSHostingView<V>, size: NSSize) -> NSWindow {
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.isOpaque = true
        window.backgroundColor = .windowBackgroundColor
        window.contentView = host; host.layoutSubtreeIfNeeded()
        window.makeKeyAndOrderFront(nil); window.displayIfNeeded()
        return window
    }
    @MainActor private func capture<V: View>(_ content: V, size: NSSize, dark: Bool, name: String, output: URL) async throws {
        let host = NSHostingView(rootView: content.background(AppPalette.panel).preferredColorScheme(dark ? .dark : .light))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let window = hostWindow(host, size: size)
        defer { window.orderOut(nil); window.contentView = nil }
        try await Task.sleep(nanoseconds: 35_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }
    @MainActor private func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    @MainActor private func accessibilityNodes(_ element: Any, depth: Int = 0) -> [NSObject] {
        guard depth < 30, let node = element as? NSObject else { return [] }
        return [node] + ((axValue(node, key: "accessibilityChildren") as? [Any]) ?? []).flatMap { accessibilityNodes($0, depth: depth + 1) }
    }
    @MainActor private func axValue(_ element: NSObject, key: String) -> Any? {
        let selector = NSSelectorFromString(key)
        guard element.responds(to: selector) else { return nil }
        return element.perform(selector)?.takeUnretainedValue()
    }
}
