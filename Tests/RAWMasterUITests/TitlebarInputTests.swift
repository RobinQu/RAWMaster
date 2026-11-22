import AppKit
import XCTest
@testable import RAWMaster

final class TitlebarInputTests: XCTestCase {
    @MainActor private final class RoutingWindow: NSWindow {
        var zoomRequests = 0
        var dragRequests = 0
        override func performDrag(with event: NSEvent) { dragRequests += 1 }
        override func performZoom(_ sender: Any?) { zoomRequests += 1 }
    }

    @MainActor private func window() -> RoutingWindow {
        _ = NSApplication.shared
        let window = RoutingWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        return window
    }

    @MainActor private func event(_ window: NSWindow, at point: NSPoint, clicks: Int = 2,
                                  type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 1,
                                        windowNumber: window.windowNumber, context: nil, eventNumber: 1,
                                        clickCount: clicks, pressure: 1))
    }

    @MainActor func testTitlebarDoubleClickRoutesOnceAndPhotoAreaDoesNotZoom() throws {
        let window = window(); defer { window.close() }
        let title = NSPoint(x: window.frame.midX, y: window.frame.height - 8)
        XCTAssertTrue(TitlebarInputRouter.handle(try event(window, at: title), in: window))
        XCTAssertEqual(window.zoomRequests, 1)
        let photo = NSPoint(x: window.frame.midX, y: window.contentLayoutRect.midY)
        XCTAssertFalse(TitlebarInputRouter.handle(try event(window, at: photo), in: window))
        XCTAssertEqual(window.zoomRequests, 1)
    }

    @MainActor func testBlankTitlebarMouseDownStartsDragAndOtherEventsKeepNativeInput() throws {
        let window = window(), other = self.window(); defer { window.close(); other.close() }
        let title = NSPoint(x: 500, y: window.frame.height - 8)
        XCTAssertTrue(TitlebarInputRouter.handle(try event(window, at: title, clicks: 1), in: window))
        XCTAssertFalse(TitlebarInputRouter.handle(try event(window, at: title, type: .rightMouseDown), in: window))
        XCTAssertFalse(TitlebarInputRouter.handle(try event(other, at: title), in: window))
        XCTAssertEqual(window.zoomRequests, 0)
        XCTAssertEqual(window.dragRequests, 1)
    }

    @MainActor func testWindowButtonsAndResizeEdgesAreNotDragAreas() throws {
        let window = window(); defer { window.close() }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            XCTAssertFalse(TitlebarInputRouter.isBlankTitlebar(point, in: window))
        }
        XCTAssertFalse(TitlebarInputRouter.isBlankTitlebar(NSPoint(x: 1, y: window.frame.height - 8), in: window))
    }

    @MainActor private final class Toolbar: NSObject, NSToolbarDelegate {
        let workflow = NSButton(title: "编辑", target: nil, action: nil)
        let action = NSButton(title: "照片信息", target: nil, action: nil)
        let workflowID = NSToolbarItem.Identifier("test.workflow")
        let actionID = NSToolbarItem.Identifier("test.inspector")
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [workflowID, .flexibleSpace, actionID] }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [workflowID, .flexibleSpace, actionID] }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = id == workflowID ? workflow : action
            return item
        }
    }

    @MainActor func testWorkflowAndSidebarControlsKeepTheirClicks() throws {
        let window = window(); defer { window.close() }
        let delegate = Toolbar(), toolbar = NSToolbar(identifier: "TitlebarRoutingTest")
        toolbar.delegate = delegate; toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [delegate.workflowID]
        window.toolbarStyle = .unified; window.toolbar = toolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(delegate.action.bounds.width, 0)
        let actionPoint = delegate.action.convert(NSPoint(x: delegate.action.bounds.midX, y: delegate.action.bounds.midY), to: nil)
        XCTAssertFalse(TitlebarInputRouter.isBlankTitlebar(actionPoint, in: window))
        let workflowPoint = delegate.workflow.convert(NSPoint(x: delegate.workflow.bounds.midX, y: delegate.workflow.bounds.midY), to: nil)
        XCTAssertFalse(TitlebarInputRouter.isBlankTitlebar(workflowPoint, in: window))
        let blank = NSPoint(x: window.frame.width * 0.3, y: workflowPoint.y)
        XCTAssertTrue(TitlebarInputRouter.isBlankTitlebar(blank, in: window))
    }
}
