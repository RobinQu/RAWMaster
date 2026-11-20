import AppKit
import SwiftUI

/// QA-only witness for the App-owned Workbench subtree. Never owns an image or a window.
@MainActor final class QAWorkbenchTeardown: ObservableObject {
    struct Result: Equatable {
        let watched: Int
        let remaining: Int
        var outcome: String {
            if watched == 0 { return "no-mounted-view" }
            return remaining == 0 ? "dismantled-and-detached" : "timeout"
        }
    }

    @Published private(set) var unmountRequested = false
    private var mounted: Set<ObjectIdentifier> = []
    private var pending: Set<ObjectIdentifier> = []
    private var completion: CheckedContinuation<Int, Never>?
    var mountedCount: Int { mounted.count }

    func markerChanged(_ marker: NSView, dismantled: Bool) {
        let id = ObjectIdentifier(marker)
        if marker.window != nil {
            mounted.insert(id)
        } else {
            mounted.remove(id)
            if dismantled, pending.remove(id) != nil, pending.isEmpty { finish() }
        }
    }

    /// The existing termination owner calls this once, after it stops editing admission.
    func unmount(timeout: Duration = .seconds(1)) async -> Result {
        precondition(!unmountRequested)
        pending = mounted
        let watched = pending.count
        unmountRequested = true
        guard !pending.isEmpty else { return .init(watched: watched, remaining: 0) }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        let timer = Task { @MainActor in
            do { try await clock.sleep(until: deadline) } catch { return }
            finish()
        }
        let remaining = await withCheckedContinuation { completion = $0 }
        timer.cancel()
        await timer.value
        return .init(watched: watched, remaining: remaining)
    }

    private func finish() {
        let waiter = completion
        completion = nil
        waiter?.resume(returning: pending.count)
    }
}

struct QAWorkbenchTeardownMarker: NSViewRepresentable {
    let probe: QAWorkbenchTeardown

    func makeNSView(context: Context) -> Marker { Marker(probe: probe) }
    func updateNSView(_ view: Marker, context: Context) {}
    static func dismantleNSView(_ view: Marker, coordinator: ()) { view.dismantle() }

    final class Marker: NSView {
        private weak var probe: QAWorkbenchTeardown?
        private var dismantled = false

        init(probe: QAWorkbenchTeardown) {
            self.probe = probe
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            probe?.markerChanged(self, dismantled: dismantled)
        }
        func dismantle() {
            dismantled = true
            probe?.markerChanged(self, dismantled: true)
        }
    }
}
