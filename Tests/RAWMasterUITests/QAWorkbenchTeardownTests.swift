import AppKit
import SwiftUI
import XCTest
@testable import RAWMaster

@MainActor final class QAWorkbenchTeardownTests: XCTestCase {
    private struct MarkerHost: View {
        @ObservedObject var probe: QAWorkbenchTeardown

        var body: some View {
            Color.clear.frame(width: 20, height: 20).background {
                if !probe.unmountRequested { QAWorkbenchTeardownMarker(probe: probe) }
            }
        }
    }

    func testNoMountedViewDoesNotWaitForDismantle() async {
        let probe = QAWorkbenchTeardown()
        let result = await probe.unmount(timeout: .milliseconds(30))
        XCTAssertTrue(probe.unmountRequested)
        XCTAssertEqual(result.outcome, "no-mounted-view")
        XCTAssertEqual(result.watched, 0)
        XCTAssertEqual(result.remaining, 0)
    }

    func testSwiftUIActuallyDismantlesAndDetachesMountedMarker() async throws {
        let probe = QAWorkbenchTeardown()
        let host = NSHostingView(rootView: MarkerHost(probe: probe))
        let window = attachToHiddenWindow(host)
        defer { window.contentView = nil; window.close() }
        for _ in 0..<50 where probe.mountedCount == 0 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(probe.mountedCount, 1)
        guard probe.mountedCount == 1 else { return }

        let unmount = Task { await probe.unmount() }
        // Exercise the actual hosting lifecycle, with no input events or visible window.
        for _ in 0..<50 where !probe.unmountRequested || probe.mountedCount != 0 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        let result = await unmount.value
        XCTAssertEqual(result.outcome, "dismantled-and-detached")
        XCTAssertEqual(result.watched, 1)
        XCTAssertEqual(result.remaining, 0)
        XCTAssertEqual(probe.mountedCount, 0)
        XCTAssertFalse(window.isVisible)
    }

    func testTimeoutContinuesShutdownAndOnlyOriginalOwnerReplies() async {
        let probe = QAWorkbenchTeardown()
        let marker = QAWorkbenchTeardownMarker.Marker(probe: probe)
        let window = attachToHiddenWindow(marker)
        defer { window.contentView = nil; window.close() }
        XCTAssertEqual(probe.mountedCount, 1)
        guard probe.mountedCount == 1 else { return }

        let owner = ApplicationTerminationOwner()
        let replied = expectation(description: "the original owner replies after bounded wait")
        replied.assertForOverFulfill = true
        var result: QAWorkbenchTeardown.Result?, subsequentClose = false, extraReply = false
        XCTAssertEqual(owner.request(shutdown: {
            result = await probe.unmount(timeout: .milliseconds(50))
            subsequentClose = true
        }, reply: {
            XCTAssertTrue(subsequentClose)
            replied.fulfill()
        }), .terminateLater)
        XCTAssertEqual(owner.request(shutdown: nil, reply: { extraReply = true }), .terminateLater)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertFalse(extraReply)
        XCTAssertEqual(result?.outcome, "timeout")
        XCTAssertEqual(result?.watched, 1)
        XCTAssertEqual(result?.remaining, 1)
        XCTAssertEqual(probe.mountedCount, 1)
    }

    private func attachToHiddenWindow(_ view: NSView) -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 20, height: 20),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        return window
    }
}
