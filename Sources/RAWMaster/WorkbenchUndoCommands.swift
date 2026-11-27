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
        route(model: model, window: window, redo: false)
    }
    static func redo(model: AppModel?, window: NSWindow?) {
        route(model: model, window: window, redo: true)
    }
    private static func route(model: AppModel?, window: NSWindow?, redo: Bool) {
        guard let window else { return }
        if let editor = window.firstResponder as? NSTextView {
            routeText(editor.undoManager, redo: redo)
            return
        }
        if let field = window.firstResponder as? NSTextField {
            routeText(field.currentEditor()?.undoManager, redo: redo)
            return
        }
        guard WorkbenchWindowContext.contains(window), model?.isLibraryTransitioning != true else { return }
        if let control = window.firstResponder as? DevelopmentEditingControl {
            if model?.isNativeEditing == true {
                if redo { control.redoAction?() } else { control.undoAction?() }
            }
            return
        }
        if model?.isNativeEditing == true {
            guard let editing = model?.editing else { return }
            if editing.stepSceneHistory(redo: redo) { return }
            if let context = editing.developmentContext { editing.undoDevelopment(context: context, redo: redo) }
            return
        }
        guard !redo else { return }
        model?.undo()
    }
    private static func routeText(_ manager: UndoManager?, redo: Bool) {
        if redo { if manager?.canRedo == true { manager?.redo() } }
        else if manager?.canUndo == true { manager?.undo() }
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
            Button("重做") { WorkbenchUndoRouting.redo(model: model, window: NSApp.keyWindow) }
                .keyboardShortcut("z", modifiers: [.command, .shift])
        }
    }
}
