import AppKit
import SwiftUI

private struct WorkbenchFocusedModelKey: FocusedValueKey { typealias Value = AppModel }
extension FocusedValues {
    var workbenchModel: AppModel? {
        get { self[WorkbenchFocusedModelKey.self] }
        set { self[WorkbenchFocusedModelKey.self] = newValue }
    }
}

/// Presentation-only window registration; no undo history or catalogue state lives here.
@MainActor
enum WorkbenchWindowContext {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    static func register(_ window: NSWindow) { windows.add(window) }
    static func unregister(_ window: NSWindow) { windows.remove(window) }
    static func contains(_ window: NSWindow) -> Bool { windows.contains(window) }
}
final class WorkbenchKeyAnchor: NSView {
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window, window !== newWindow { WorkbenchWindowContext.unregister(window) }
        super.viewWillMove(toWindow: newWindow)
    }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { WorkbenchWindowContext.register(window) }
    }
}

@MainActor
enum WorkbenchUndoRouting {
    static func undo(model: AppModel?, window: NSWindow?) {
        guard let window else { return }
        if let responder = window.firstResponder, responder is NSTextView || responder is NSTextField {
            if let manager = responder.undoManager, manager.canUndo { manager.undo() }
            return
        }
        guard WorkbenchWindowContext.contains(window) else { return }
        model?.undo()
    }
}

struct WorkbenchUndoCommands: Commands {
    @FocusedValue(\.workbenchModel) private var model
    var body: some Commands {
        CommandGroup(replacing: .undoRedo) {
            // Keep enabled so a native field editor can supply its own undo availability.
            // Routing is checked at dispatch time, including when Settings is the key window.
            Button("撤销") { WorkbenchUndoRouting.undo(model: model, window: NSApp.keyWindow) }
                .keyboardShortcut("z", modifiers: .command)
        }
    }
}
