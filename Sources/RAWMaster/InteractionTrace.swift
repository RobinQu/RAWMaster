import AppKit
import SwiftUI

/// Opt-in local diagnostics. Timestamping precedes asynchronous disk output; no images or paths are logged.
@MainActor
final class InteractionTrace {
    static let shared = InteractionTrace()
    private let writer: DispatchQueue = DispatchQueue(label: "RAWMaster.interaction-trace", qos: .utility)
    private let destination: URL?
    private var monitor: Any?
    private var operation: String?
    private var inputKind = "none"
    private var committed: [String: String] = [:]
    private var updated: Set<String> = []

    private init() {
        let arguments = ProcessInfo.processInfo.arguments
        let path = arguments.firstIndex(of: "--interaction-trace").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
            ?? ProcessInfo.processInfo.environment["RAWMASTER_INTERACTION_TRACE"]
        destination = path.map { URL(fileURLWithPath: $0) }
    }
    func install() {
        guard destination != nil, monitor == nil else { return }
        record("session", fields: ["boundary": "native-event-to-selection-and-NSView-update; not-display-presentation",
                                  "os": ProcessInfo.processInfo.operatingSystemVersionString,
                                  "doubleClickIntervalMs": NSEvent.doubleClickInterval * 1000])
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type != .leftMouseUp {
                self.operation = UUID().uuidString
                self.inputKind = event.type == .keyDown ? "keyboard" : "pointer"
            }
            self.record(event.type == .leftMouseDown ? "input.down" : (event.type == .leftMouseUp ? "input.up" : "input.key"),
                        time: event.timestamp,
                        fields: event.type == .keyDown ? ["keyCode": event.keyCode] : ["clickCount": event.clickCount])
            return event
        }
    }
    func selectionCommitted(assetID: String, changed: Bool, count: Int) {
        guard destination != nil, let operation else { return }
        committed[assetID] = operation
        record("selection.commit", fields: ["assetID": assetID, "changed": changed, "selectedCount": count])
    }
    func selectionViewUpdated(assetID: String?) {
        guard destination != nil, let assetID, let token = committed[assetID], !updated.contains(token) else { return }
        updated.insert(token)
        record("selection.view-update", token: token, fields: ["assetID": assetID])
    }
    func flush() { writer.sync {} }
    private func record(_ event: String, time: TimeInterval = ProcessInfo.processInfo.systemUptime,
                        token: String? = nil, fields: [String: Any] = [:]) {
        guard let destination else { return }
        var row = fields
        row["event"] = event; row["uptimeSeconds"] = time
        row["operationID"] = token ?? operation ?? "session"; row["inputKind"] = inputKind
        guard JSONSerialization.isValidJSONObject(row), let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        writer.async {
            do {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if !FileManager.default.fileExists(atPath: destination.path) { FileManager.default.createFile(atPath: destination.path, contents: nil) }
                let handle = try FileHandle(forWritingTo: destination)
                defer { try? handle.close() }
                try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
            } catch { NSLog("Interaction trace write failed: %@", error.localizedDescription) }
        }
    }
}

/// Records an AppKit view update after SwiftUI has consumed the focused selection.
/// This does not claim that WindowServer has presented a frame.
struct SelectionUpdateProbe: NSViewRepresentable {
    let assetID: String?
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ nsView: NSView, context: Context) { InteractionTrace.shared.selectionViewUpdated(assetID: assetID) }
}
