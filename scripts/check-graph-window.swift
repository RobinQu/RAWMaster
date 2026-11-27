// From another process, exercise the Graph on a visible QA workbench with real pointer events.
import AppKit
import ApplicationServices

struct Failure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var object: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &object) == .success ? object : nil
}
func value(_ element: AXUIElement, _ name: String) -> String { attribute(element, name) as? String ?? "" }
func bounds(_ element: AXUIElement) throws -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    guard let pos = attribute(element, "AXPosition"), CFGetTypeID(pos) == AXValueGetTypeID(),
          let dim = attribute(element, "AXSize"), CFGetTypeID(dim) == AXValueGetTypeID(),
          AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(dim as! AXValue, .cgSize, &s) else {
        throw Failure("Cannot read AXPosition/AXSize")
    }
    return CGRect(origin: p, size: s)
}
func array(_ r: CGRect) -> [Int] { [r.minX, r.minY, r.width, r.height].map { Int($0.rounded()) } }
func children(_ e: AXUIElement) -> [AXUIElement] { attribute(e, "AXChildren") as? [AXUIElement] ?? [] }
func find(_ e: AXUIElement, depth: Int = 0, matching: (AXUIElement) -> Bool) -> AXUIElement? {
    if matching(e) { return e }
    guard depth < 22 else { return nil }
    for c in children(e) { if let match = find(c, depth: depth + 1, matching: matching) { return match } }
    return nil
}
func wait<T>(_ label: String, _ operation: () -> T?) throws -> T {
    for _ in 0..<36 { if let result = operation() { return result }; usleep(100_000) }
    throw Failure("Timed out: " + label)
}
func press(_ element: AXUIElement) throws {
    let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
    guard result == .success else { throw Failure("AXPress " + String(result.rawValue)) }
}
func key(_ code: CGKeyCode, flags: CGEventFlags = []) throws {
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) else { throw Failure("No key event") }
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
    usleep(160_000)
}
func drag(_ p: CGPoint, _ delta: CGSize, expectedPID: pid_t, cancel: Bool = false) throws {
    var hit: AXUIElement?
    let located = AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(p.x), Float(p.y), &hit)
    var pid: pid_t = -1
    guard located == .success, let hit, AXUIElementGetPid(hit, &pid) == .success, pid == expectedPID else {
        throw Failure("Drag start is not above the isolated app: " + String(describing: p))
    }
    let source = CGEventSource(stateID: .hidSystemState)
    func send(_ type: CGEventType, progress: CGFloat) throws {
        let point = CGPoint(x: p.x + delta.width * progress, y: p.y + delta.height * progress)
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left) else {
            throw Failure("No event source")
        }
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.post(tap: .cghidEventTap)
        usleep(22_000)
    }
    try send(.mouseMoved, progress: 0)
    try send(.leftMouseDown, progress: 0)
    for i in 1...12 { try send(.leftMouseDragged, progress: CGFloat(i) / 12) }
    if cancel { try key(53) }
    try send(.leftMouseUp, progress: 1)
    usleep(180_000)
}
func run() throws {
    let args = CommandLine.arguments
    guard args.count == 4, let pid = Int32(args[1]), let app = NSRunningApplication(processIdentifier: pid),
          ["只读兼容图", "工作流 Graph"].contains(args[2]) else {
        throw Failure("graph-drag <isolated app pid> <window title> <output directory>")
    }
    let title = args[2], scene = title == "工作流 Graph", out = URL(fileURLWithPath: args[3])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard AXIsProcessTrusted(), CGPreflightPostEventAccess() else { throw Failure("AX/CGEvent access unavailable") }
    _ = app.activate()
    let ax = AXUIElementCreateApplication(pid)
    func windows() -> [AXUIElement] { attribute(ax, "AXWindows") as? [AXUIElement] ?? [] }
    func graph() -> AXUIElement? { windows().first { value($0, "AXTitle") == title } }
    let toggleID = scene ? "editing.scene.graph.toggle" : "editing.compatibilityGraph"
    func toggle(_ owner: AXUIElement) -> AXUIElement? {
        find(owner) { value($0, "AXIdentifier") == toggleID || value($0, "AXDescription") == "Graph 窗口" }
    }
    let owner = try wait("workbench") { windows().first { value($0, "AXTitle") != title && toggle($0) != nil } }
    if graph() == nil { try press(try wait("open button") { toggle(owner) }) }
    let window = try wait("native graph") { graph() }
    guard AXUIElementPerformAction(window, "AXRaise" as CFString) == .success,
          let close = attribute(window, "AXCloseButton"), CFGetTypeID(close) == AXUIElementGetTypeID(),
          value(close as! AXUIElement, "AXSubrole") == "AXCloseButton" else {
        throw Failure("System red close button missing")
    }
    let ownerBefore = try bounds(owner), original = try bounds(window)
    func node(_ panel: AXUIElement) -> AXUIElement? {
        find(panel) { e in
            if scene { return value(e, "AXIdentifier").hasPrefix("scene.graph.node.") }
            return [value(e, "AXDescription"), value(e, "AXValue"), value(e, "AXTitle")].contains { $0.contains("兼容显影") }
        }
    }
    func relativeNode(_ panel: AXUIElement) throws -> CGRect {
        let b = try bounds(panel), n = try bounds(try wait("graph node") { node(panel) })
        return n.offsetBy(dx: -b.minX, dy: -b.minY)
    }
    if scene, let fit = find(window, matching: { value($0, "AXIdentifier") == "scene.graph.fit" }),
       let first = node(window), !original.insetBy(dx: 12, dy: 30).contains(try bounds(first)) {
        try press(fit)
        usleep(180_000)
    }
    func capture(_ frame: CGRect, _ name: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-R" + array(frame).map(String.init).joined(separator: ","), out.appendingPathComponent(name + ".png").path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure("Capture failed") }
    }
    let n0 = try relativeNode(window), closeBox = try bounds(close as! AXUIElement)
    let titlePoint = CGPoint(x: original.minX + original.width * 0.61, y: closeBox.midY)
    var disp: UInt32 = 0, count: UInt32 = 0
    guard CGGetDisplaysWithPoint(titlePoint, 1, &disp, &count) == .success, count == 1 else { throw Failure("No display") }
    let screen = CGDisplayBounds(disp), visible = ownerBefore.intersection(screen)
    let dx: CGFloat = original.minX - visible.minX > 85 ? -72 : 72
    let dy: CGFloat = original.minY - visible.minY > 66 ? -48 : 48
    if ownerBefore.contains(original) { try capture(ownerBefore, "workbench") }
    try capture(original, "before")
    try drag(titlePoint, CGSize(width: dx, height: dy), expectedPID: pid)
    let moved = try bounds(window), n1 = try relativeNode(window)
    guard moved.size == original.size, abs(moved.minX - original.minX - dx) <= 8,
          abs(moved.minY - original.minY - dy) <= 8, array(n1) == array(n0) else {
        throw Failure("Bad title drag: " + String(describing: [array(original), array(moved), array(n0), array(n1)]))
    }
    let canvasPoint = CGPoint(x: moved.midX - 14, y: moved.maxY - 58)
    let pan = CGSize(width: 43, height: -27)
    try drag(canvasPoint, pan, expectedPID: pid)
    let afterCanvas = try bounds(window), n2 = try relativeNode(window)
    guard moved == afterCanvas, try bounds(owner) == ownerBefore else { throw Failure("Canvas moved a window") }
    if scene {
        guard abs(n2.minX - n1.minX - pan.width) <= 2, abs(n2.minY - n1.minY - pan.height) <= 2 else {
            throw Failure("Graph did not pan by the delivered delta: " + String(describing: [array(n1), array(n2)]))
        }
    } else if array(n2) != array(n1) { throw Failure("Read-only graph changed") }
    try capture(afterCanvas, "after")
    var nodeAfterDrag: CGRect?
    var nodeEvidence: [String: Any] = [:]
    if scene {
        let selection = try wait("movable node") { node(window) }
        let before = try bounds(selection)
        let anchor = CGPoint(x: before.midX, y: before.midY)
        let delta = CGSize(width: 37, height: 53)
        let finalPort = try wait("final port") { find(window) { value($0, "AXIdentifier") == "scene.graph.port.final" } }
        let portBefore = try bounds(finalPort)
        try drag(anchor, delta, expectedPID: pid, cancel: true)
        guard graph() != nil, try bounds(selection) == before, try bounds(finalPort) == portBefore else {
            throw Failure("Escape did not restore the original node and keep Graph open")
        }
        try drag(anchor, delta, expectedPID: pid)
        let after = try bounds(selection)
        guard abs(after.minX - before.minX - delta.width) <= 2, abs(after.minY - before.minY - delta.height) <= 2,
              try bounds(finalPort) == portBefore, try bounds(window) == afterCanvas else {
            throw Failure("Node drag did not move just the selected card: " + String(describing: [array(before), array(after)]))
        }
        try key(124, flags: .maskShift)
        let keyboard = try bounds(selection)
        let readable = find(window) { value($0, "AXIdentifier") == "scene.graph.readable" }
        let zoom = readable.flatMap { Double(value($0, "AXValue").dropLast()) } ?? 100
        guard abs(keyboard.minX - after.minX - 16 * zoom / 100) <= 2, keyboard.minY == after.minY else {
            throw Failure("Shift+Right did not move the focused node: " + String(describing: [array(after), array(keyboard)]))
        }
        nodeAfterDrag = try relativeNode(window)
        try capture(afterCanvas, "node-moved")
        nodeEvidence = ["before": array(before), "cancelled": array(before), "pointer": array(after),
                        "keyboard": array(keyboard), "fixedOutputPort": array(portBefore)]
    }
    let rightEdge = CGPoint(x: moved.maxX - 1, y: moved.midY + 52)
    try drag(rightEdge, CGSize(width: -32, height: 0), expectedPID: pid)
    let resized = try bounds(window)
    guard resized.origin == moved.origin, resized.height == moved.height, abs(resized.width - moved.width + 32) <= 5 else {
        throw Failure("Right-edge resize did not change only the window width: " + String(describing: [array(moved), array(resized)]))
    }
    try press(close as! AXUIElement)
    _ = try wait("red close") { graph() == nil ? true : nil }
    let focused = attribute(ax, "AXFocusedUIElement")
    let focusedID = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? value($0 as! AXUIElement, "AXIdentifier") : nil } ?? ""
    try press(try wait("reopen button") { toggle(owner) })
    let reopened = try wait("reopened graph") { graph() }, final = try bounds(reopened)
    guard final == resized else { throw Failure("Reopen discarded window geometry") }
    if let nodeAfterDrag {
        let restored = try relativeNode(reopened)
        guard array(restored) == array(nodeAfterDrag) else { throw Failure("Reopen discarded node placement") }
        try press(try wait("organize button") { find(reopened) { value($0, "AXIdentifier") == "scene.graph.organize" } })
        usleep(180_000)
        let organized = try relativeNode(reopened)
        guard organized != restored else { throw Failure("Arrange kept an explicit node placement") }
        try capture(final, "organized")
        nodeEvidence["afterReopen"] = array(restored)
        nodeEvidence["afterOrganize"] = array(organized)
    }
    let report: [String: Any] = ["title": title, "bundle": app.bundleURL?.lastPathComponent ?? "", "pid": pid, "os": ProcessInfo.processInfo.operatingSystemVersionString,
        "input": "CGEvent.cghidEventTap mouseMoved/leftMouseDown/12 leftMouseDragged/leftMouseUp; AXPosition/AXSize read back from independent process",
        "windowRole": value(reopened, "AXRole"), "windowSubrole": value(reopened, "AXSubrole"), "nativeClose": "AXCloseButton/AXPress",
        "displayID": disp, "ownerFrame": array(ownerBefore), "initial": array(original), "titlePoint": [titlePoint.x, titlePoint.y],
        "requestedTitleDrag": [dx, dy], "observedTitleDrag": [moved.minX-original.minX, moved.minY-original.minY], "afterTitleDrag": array(moved), "canvasDrag": [pan.width, pan.height], "afterCanvasDrag": array(afterCanvas),
        "nodeInitiallyRelative": array(n0), "nodeAfterTitleRelative": array(n1), "nodeAfterCanvasRelative": array(n2), "afterRightEdgeDrag": array(resized), "reopened": array(final),
        "focusAfterClose": focusedID, "nodePlacement": nodeEvidence]
    let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: out.appendingPathComponent("graph-window.json"))
    print(title + " passed")
}
do { try run() } catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
