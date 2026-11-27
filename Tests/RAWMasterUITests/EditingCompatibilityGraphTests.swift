import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import RAWMaster
@testable import RAWMasterCore

final class EditingCompatibilityGraphTests: XCTestCase {
    @MainActor func testCompatibilityGraphPanelKeepsOwnerNonmodalAndClosesOnContextChange() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: CGRect(x: 80, y: 120, width: 640, height: 480), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        owner.orderFront(nil)
        let presenter = EditingCompatibilityGraphPanel()
        presenter.anchor = owner.contentView
        let source = EditingSourceSnapshot(projectID: "p", assetID: "a", contentSHA256: String(repeating: "a", count: 64),
            byteCount: 1024, admissionFingerprint: String(repeating: "b", count: 64), sourceLocation: URL(fileURLWithPath: "/sample.ARW"))
        let version = EditingVersion(workID: "w", parentVersionID: nil, kind: .original, source: source)
        let projection = try DevelopmentCompatibilityGraphV1(version)
        let ownerFrame = owner.frame
        var restored = 0
        presenter.show(projection, photoName: "sample.ARW", returnFocus: { restored += 1 })
        let panel = try XCTUnwrap(presenter.panel)
        XCTAssertTrue(panel.isVisible && owner.isVisible)
        XCTAssertTrue(panel.parent === owner)
        XCTAssertTrue(panel.styleMask.isSuperset(of: [.titled, .utilityWindow, .closable, .resizable]))
        XCTAssertTrue(panel.isMovable)
        XCTAssertFalse(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isEnabled, true)
        XCTAssertTrue(panel.canBecomeKey)
        XCTAssertEqual(panel.title, "只读兼容图")
        XCTAssertEqual(ResolvedAppearance.resolve(panel.effectiveAppearance), .light)
        presenter.setAppearance(.dark)
        XCTAssertEqual(ResolvedAppearance.resolve(panel.effectiveAppearance), .dark)
        let titleHeight = panel.frame.height - panel.contentLayoutRect.height
        XCTAssertGreaterThan(titleHeight, 0)
        XCTAssertLessThanOrEqual(titleHeight, 38)
        XCTAssertNil(owner.attachedSheet)
        XCTAssertEqual(owner.frame, ownerFrame)
        XCTAssertEqual(presenter.openWorkID, version.workID)
        let expanded = panel.frame
        XCTAssertGreaterThanOrEqual(expanded.height, 392)
        XCTAssertGreaterThanOrEqual(expanded.width, 520)
        panel.contentView?.layoutSubtreeIfNeeded()
        let menu = try XCTUnwrap(panel.titlebarAccessoryViewControllers.first?.view as? GraphWindowMenu)
        XCTAssertEqual(menu.accessibilityLabel(), "图窗操作")
        let commands = try XCTUnwrap(menu.menu)
        commands.performActionForItem(at: commands.indexOfItem(withTitle: "调整大小…"))
        try sendKey(123, characters: "\u{f702}", to: panel)
        XCTAssertEqual(panel.frame.width, expanded.width - 16)
        try sendKey(53, characters: "\u{1b}", to: panel)
        XCTAssertNil(menu.adjustment)
        XCTAssertTrue(panel.isVisible)
        commands.performActionForItem(at: commands.indexOfItem(withTitle: "移动窗口…"))
        try sendKey(124, characters: "\u{f703}", to: panel)
        XCTAssertEqual(panel.frame.minX, expanded.minX + 16)
        try sendKey(36, characters: "\r", to: panel)
        XCTAssertNil(menu.adjustment)
        presenter.resetPosition()
        commands.performActionForItem(at: commands.indexOfItem(withTitle: "收起窗口"))
        XCTAssertEqual(panel.frame.height, 30)
        commands.performActionForItem(at: commands.indexOfItem(withTitle: "展开窗口"))
        XCTAssertEqual(panel.frame, expanded)
        presenter.toggleFold()
        commands.performActionForItem(at: commands.indexOfItem(withTitle: "复位窗口"))
        XCTAssertEqual(panel.frame, expanded)
        let short = NSRect(x: expanded.minX, y: expanded.maxY - 256, width: expanded.width, height: 256)
        panel.setFrame(short, display: true)
        XCTAssertEqual(panel.frame.height, 256)
        XCTAssertEqual(panel.contentLayoutRect.height, 256 - titleHeight)
        presenter.setCanvasToolActive(true)
        XCTAssertFalse(panel.isVisible)
        XCTAssertEqual(presenter.openWorkID, version.workID)
        presenter.setCanvasToolActive(false)
        XCTAssertTrue(panel.isVisible)
        XCTAssertEqual(panel.frame, short)
        presenter.resetPosition()
        if let visible = panel.screen?.visibleFrame { XCTAssertTrue(visible.contains(panel.frame)) }
        try sendKey(53, characters: "\u{1b}", to: panel)
        XCTAssertEqual(restored, 1)
        XCTAssertNil(presenter.openWorkID)
        XCTAssertTrue(owner.childWindows?.isEmpty ?? true)
        presenter.show(projection, photoName: "sample.ARW", returnFocus: { restored += 1 })
        presenter.fitToContext("next-work")
        XCTAssertNil(presenter.panel)
        XCTAssertEqual(restored, 1, "context changes must not focus the old photo's control")
        XCTAssertEqual(owner.frame, ownerFrame)
    }

    @MainActor func testCompatibilityGraphButtonUsesPrototypePhotoAndRetainsDarkroomState() async throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/dji187-context376/files/asset0000.jpg")
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhancedUI = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhancedUI)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhancedUI)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhancedUI) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("compatibility.sqlite")
        let sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("sunset.jpg")
        try FileManager.default.copyItem(at: fixture, to: source)
        let asset = try NativePresentedCanvasTests.register(source: source, library: library, requiresRAW: false)
        let name = "RAWMaster-compatibility-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        let editing = try XCTUnwrap(model.editing, model.errorMessage ?? "Editor unavailable")
        let window = NSWindow(contentRect: NSRect(x: 70, y: 120, width: 900, height: 610), styleMask: [.titled, .closable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: ZStack(alignment: .topTrailing) {
            EditingImageCanvas(editing: editing).environmentObject(model)
            EditingCompatibilityGraphToolbar(editing: editing).frame(width: 304)
        })
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await wait { editing.sourceReady && editing.previews.primary.frame != nil }
            let before = editing.recipe, version = editing.selectedVersionID, workID = editing.work?.id
            let frame = editing.previews.primary.frame?.id, command = editing.canvasCommand?.id
            func trigger() -> NSObject? {
                element(in: window, selector: "accessibilityIdentifier", equals: "editing.compatibilityGraph")
            }
            try await wait {
                host.layoutSubtreeIfNeeded()
                return trigger() != nil
            }
            let button = try XCTUnwrap(trigger())
            try press(button)
            try await wait { window.childWindows?.contains(where: { $0.title == "只读兼容图" }) == true }
            let panel = try XCTUnwrap(window.childWindows?.first(where: { $0.title == "只读兼容图" }))
            XCTAssertNil(window.attachedSheet)
            XCTAssertTrue(window.isVisible && panel.isVisible)
            XCTAssertEqual(panel.standardWindowButton(.closeButton)?.isEnabled, true)
            XCTAssertNotNil(element(in: panel, selector: "accessibilityIdentifier", equals: "scene.graph.window.menu"))
            func zoomButton(_ suffix: String, in window: NSWindow) -> NSObject? {
                element(in: window, selector: "accessibilityIdentifier", equals: "scene.graph.compatibility.zoom." + suffix)
            }
            func zoomValue(_ panel: NSWindow) -> String? {
                let value = NSSelectorFromString("accessibilityValue")
                guard let button = zoomButton("reset", in: panel), button.responds(to: value) else { return nil }
                return button.perform(value)?.takeUnretainedValue() as? String
            }
            try press(try XCTUnwrap(zoomButton("in", in: panel)))
            try await wait { zoomValue(panel) == "120%" }
            panel.performClose(nil)
            try await wait { window.childWindows?.isEmpty ?? true }
            try press(try XCTUnwrap(trigger()))
            try await wait { window.childWindows?.first(where: { $0.title == "只读兼容图" }) != nil }
            let reopened = try XCTUnwrap(window.childWindows?.first { $0.title == "只读兼容图" })
            try await wait { zoomValue(reopened) == "120%" }
            try press(try XCTUnwrap(zoomButton("reset", in: reopened)))
            try await wait { zoomValue(reopened) == "100%" }
            editing.postNotice("已保存候选")
            func closeNotice(_ label: String) -> NSObject? {
                element(in: window, selector: "accessibilityLabel", equals: label)
            }
            try await wait { closeNotice("关闭信息通知") != nil }
            editing.postNotice("原片读取失败", kind: .error)
            try await wait { closeNotice("关闭信息通知") == nil && closeNotice("关闭错误通知") != nil }
            if let path = ProcessInfo.processInfo.environment["RAWMASTER_EDITOR_NOTICE_CAPTURE"] {
                window.displayIfNeeded()
                let image = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            }
            try press(try XCTUnwrap(closeNotice("关闭错误通知")))
            try await wait { editing.activeNotice == nil }
            XCTAssertTrue(editing.photoNotices.contains { $0.text == "原片读取失败" })
            XCTAssertTrue(editing.photoNotices.contains { $0.text == "已保存候选" })
            XCTAssertTrue(reopened.isVisible)
            XCTAssertEqual(editing.asset?.id, asset.id)
            try sendKey(53, characters: "\u{1b}", to: reopened)
            try await wait { window.childWindows?.contains(where: { $0.title == "只读兼容图" }) != true }
            XCTAssertEqual(editing.recipe, before)
            XCTAssertEqual(editing.selectedVersionID, version)
            XCTAssertEqual(editing.work?.id, workID)
            XCTAssertEqual(editing.canvasCommand?.id, command)
            XCTAssertEqual(editing.previews.primary.frame?.id, frame)
            XCTAssertFalse(editing.isDirty)
            await editing.shutdown()
        } catch { await editing.shutdown(); throw error }
    }

    @MainActor func testShippingComponentsExposeHDRModeAndBothGraphEntryPoints() async throws {
        guard ProcessInfo.processInfo.environment["RAWMASTER_EXPERIMENTAL_SCENE_DARKROOM"] != "0",
              ProcessInfo.processInfo.environment["RAWMASTER_EXPERIMENTAL_COMPATIBILITY_GRAPH"] != "0" else {
            throw XCTSkip("experimental UI disabled by environment")
        }
        XCTAssertTrue(EditingController.sceneReviewEnabled)
        XCTAssertTrue(EditingCompatibilityGraphPanel.isEnabled)
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("RAWMasterImagingTests/Fixtures/SequenceGrouping/v1/cases/dji187-context376/files/asset0000.jpg")
        _ = NSApplication.shared
        NSApp.activate(ignoringOtherApps: true)
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let priorAccessibility = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(NSNumber(value: true), forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(priorAccessibility, forAttribute: enhanced) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("shipping-ui.sqlite")
        let sourceDirectory = root.appendingPathComponent("sources", isDirectory: true)
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: false)
        let source = sourceDirectory.appendingPathComponent("shipping.jpg")
        try FileManager.default.copyItem(at: fixture, to: source)
        let asset = try NativePresentedCanvasTests.register(source: source, library: library, requiresRAW: false)
        let defaultsName = "RAWMaster-shipping-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let model = AppModel(libraryURL: library, defaults: defaults)
        let editing = try XCTUnwrap(model.editing, model.errorMessage ?? "Editor unavailable")
        let window = NSWindow(contentRect: NSRect(x: 70, y: 120, width: 340, height: 720),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            EditingSceneModeStrip(editing: editing)
            EditingCompatibilityGraphToolbar(editing: editing)
        }.frame(width: 304))
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        do {
            editing.isPresented = true
            editing.focus(asset)
            try await wait { editing.sourceReady && !editing.loading }
            for _ in 0..<30 {
                host.layoutSubtreeIfNeeded()
                if element(in: window, selector: "accessibilityIdentifier", equals: "editing.scene.mode.HDR") != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let hdr = element(in: window, selector: "accessibilityIdentifier", equals: "editing.scene.mode.HDR")
            let compat = element(in: window, selector: "accessibilityIdentifier", equals: "editing.compatibilityGraph")
            XCTAssertNotNil(hdr)
            XCTAssertNotNil(element(in: window, selector: "accessibilityIdentifier", equals: "editing.scene.mode.SDR"))
            XCTAssertNotNil(compat)
            await editing.shutdown()
        } catch { await editing.shutdown(); throw error }
    }

    @MainActor private func wait(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now + .seconds(30)
        while !condition() {
            guard ContinuousClock.now < limit else { throw Failure.timedOut }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private enum Failure: Error { case timedOut }

    @MainActor private func sendKey(_ code: UInt16, characters: String, to window: NSWindow) throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
        window.sendEvent(event)
    }

    @MainActor private func element(in root: NSObject, selector: String, equals expected: String) -> NSObject? {
        let children = NSSelectorFromString("accessibilityChildren"), field = NSSelectorFromString(selector)
        var pending = [root], visited: [ObjectIdentifier: NSObject] = [:]
        while let node = pending.popLast(), visited.count < 2048 {
            guard visited.updateValue(node, forKey: ObjectIdentifier(node)) == nil else { continue }
            if node.responds(to: field), node.perform(field)?.takeUnretainedValue() as? String == expected { return node }
            if node.responds(to: children), let list = node.perform(children)?.takeUnretainedValue() as? [NSObject] {
                pending.append(contentsOf: list)
            }
        }
        return nil
    }

    @MainActor private func press(_ button: NSObject) throws {
        let selector = NSSelectorFromString("accessibilityPerformPress")
        let implementation = try XCTUnwrap(button.method(for: selector))
        typealias Press = @convention(c) (AnyObject, Selector) -> Bool
        XCTAssertTrue(unsafeBitCast(implementation, to: Press.self)(button, selector))
    }
}
