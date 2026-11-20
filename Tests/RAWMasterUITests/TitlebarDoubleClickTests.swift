import AppKit
import XCTest
@testable import RAWMaster

final class TitlebarDoubleClickTests: XCTestCase {
    @MainActor private final class ZoomWindow: NSWindow {
        var zoomRequests = 0
        override func performZoom(_ sender: Any?) { zoomRequests += 1 }
    }

    @MainActor private func window() -> ZoomWindow {
        _ = NSApplication.shared
        let window = ZoomWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
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
        XCTAssertTrue(TitlebarDoubleClickRouter.handle(try event(window, at: title), in: window))
        XCTAssertEqual(window.zoomRequests, 1)
        let photo = NSPoint(x: window.frame.midX, y: window.contentLayoutRect.midY)
        XCTAssertFalse(TitlebarDoubleClickRouter.handle(try event(window, at: photo), in: window))
        XCTAssertEqual(window.zoomRequests, 1)
    }

    @MainActor func testSingleClickRightClickAndAnotherWindowKeepNativeInput() throws {
        let window = window(), other = self.window(); defer { window.close(); other.close() }
        let title = NSPoint(x: 500, y: window.frame.height - 8)
        XCTAssertFalse(TitlebarDoubleClickRouter.handle(try event(window, at: title, clicks: 1), in: window))
        XCTAssertFalse(TitlebarDoubleClickRouter.handle(try event(window, at: title, type: .rightMouseDown), in: window))
        XCTAssertFalse(TitlebarDoubleClickRouter.handle(try event(other, at: title), in: window))
        XCTAssertEqual(window.zoomRequests, 0)
    }

    @MainActor func testWindowControlButtonsAreNeverZoomAreas() throws {
        let window = window(); defer { window.close() }
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            let button = try XCTUnwrap(window.standardWindowButton(kind))
            let point = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: nil)
            XCTAssertFalse(TitlebarDoubleClickRouter.isZoomArea(point, in: window))
        }
        XCTAssertFalse(TitlebarDoubleClickRouter.isZoomArea(NSPoint(x: -1, y: window.frame.height - 8), in: window))
    }

    @MainActor private final class Toolbar: NSObject, NSToolbarDelegate {
        let brand = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        let action = NSButton(title: "照片信息", target: nil, action: nil)
        let brandID = NSToolbarItem.Identifier(TitlebarDoubleClickRouter.brandItemID)
        let actionID = NSToolbarItem.Identifier("test.inspector")
        func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [brandID, .flexibleSpace, actionID] }
        func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [brandID, .flexibleSpace, actionID] }
        func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar: Bool) -> NSToolbarItem? {
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = id == brandID ? brand : action
            return item
        }
    }

    @MainActor func testToolbarActionRemainsClickableWhileDecorativeBrandCanZoom() throws {
        let window = window(); defer { window.close() }
        let delegate = Toolbar(), toolbar = NSToolbar(identifier: "TitlebarRoutingTest")
        toolbar.delegate = delegate; toolbar.displayMode = .iconOnly
        toolbar.centeredItemIdentifiers = [delegate.brandID]
        window.toolbarStyle = .unified; window.toolbar = toolbar
        window.contentView?.superview?.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(delegate.action.bounds.width, 0)
        let actionPoint = delegate.action.convert(NSPoint(x: delegate.action.bounds.midX, y: delegate.action.bounds.midY), to: nil)
        XCTAssertFalse(TitlebarDoubleClickRouter.isZoomArea(actionPoint, in: window))
        let brandPoint = delegate.brand.convert(NSPoint(x: delegate.brand.bounds.midX, y: delegate.brand.bounds.midY), to: nil)
        XCTAssertTrue(TitlebarDoubleClickRouter.isZoomArea(brandPoint, in: window))
    }
}
