import AppKit
import SwiftUI

/// Window handles have their own hit targets so dragging the canvas still pans the graph.
struct GraphCanvasWindowHandle: NSViewRepresentable {
    enum Kind { case move, resize }
    let kind: Kind
    let apply: (NSRect) -> Void

    func makeNSView(context: Context) -> Handle {
        Handle(kind: kind, apply: apply)
    }

    func updateNSView(_ view: Handle, context: Context) { view.apply = apply }

    final class Handle: NSButton {
        let kind: Kind
        var apply: (NSRect) -> Void
        private var dragStart: (frame: NSRect, pointer: NSPoint)?

        init(kind: Kind, apply: @escaping (NSRect) -> Void) {
            self.kind = kind
            self.apply = apply
            super.init(frame: .zero)
            let moving = kind == .move
            let title = moving ? "移动 Graph 窗口" : "调整 Graph 窗口大小"
            let symbol = moving ? "arrow.up.and.down.and.arrow.left.and.right" : "arrow.up.left.and.arrow.down.right"
            image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            imagePosition = .imageOnly
            isBordered = false
            suppressStandardFocusRing()
            target = self
            action = #selector(focusHandle(_:))
            toolTip = moving ? "拖动或用方向键移动窗口" : "拖动或用方向键调整窗口大小"
            setAccessibilityLabel(title)
            setAccessibilityHelp(toolTip)
            let identifier = moving ? "scene.graph.window.move" : "scene.graph.window.resize"
            setAccessibilityIdentifier(identifier)
            cell?.setAccessibilityIdentifier(identifier)
            cell?.setAccessibilityLabel(title)
            cell?.setAccessibilityHelp(toolTip)
            let actions: [(String, CGFloat, CGFloat)] = [
                (moving ? "向左移动" : "减小宽度", -16, 0), (moving ? "向右移动" : "增加宽度", 16, 0),
                (moving ? "向上移动" : "减小高度", 0, 16), (moving ? "向下移动" : "增加高度", 0, -16)
            ]
            let accessibleActions = actions.map { name, dx, dy in
                NSAccessibilityCustomAction(name: name) { [weak self] in self?.step(x: dx, y: dy) ?? false }
            }
            setAccessibilityCustomActions(accessibleActions)
            cell?.setAccessibilityCustomActions(accessibleActions)
        }

        required init?(coder: NSCoder) { nil }
        @objc private func focusHandle(_ sender: Any?) { _ = focusForKeyboard() }
        override var acceptsFirstResponder: Bool { true }
        override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
        override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }
        override func accessibilityPerformPress() -> Bool { focusForKeyboard() }
        override func mouseDown(with event: NSEvent) {
            guard let window, focusForKeyboard() else { return }
            dragStart = (window.frame, NSEvent.mouseLocation)
        }
        override func mouseDragged(with event: NSEvent) {
            guard let start = dragStart else { return }
            let pointer = NSEvent.mouseLocation
            adjust(start.frame, x: pointer.x - start.pointer.x, y: pointer.y - start.pointer.y)
        }
        override func mouseUp(with event: NSEvent) { dragStart = nil }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: step(x: -16, y: 0)
            case 124: step(x: 16, y: 0)
            case 125: step(x: 0, y: -16)
            case 126: step(x: 0, y: 16)
            default: super.keyDown(with: event)
            }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            if window?.firstResponder === self {
                NSColor.secondaryLabelColor.setFill()
                NSRect(x: bounds.minX + 4, y: isFlipped ? bounds.maxY - 2 : bounds.minY, width: max(0, bounds.width - 8), height: 2).fill()
            }
        }

        private func focusForKeyboard() -> Bool {
            guard let window else { return false }
            window.makeKey()
            return window.makeFirstResponder(self)
        }

        @discardableResult private func step(x: CGFloat, y: CGFloat) -> Bool {
            guard let frame = window?.frame else { return false }
            adjust(frame, x: x, y: y)
            return true
        }

        private func adjust(_ frame: NSRect, x: CGFloat, y: CGFloat) {
            if kind == .move { apply(frame.offsetBy(dx: x, dy: y)) }
            else {
                let height = max(1, frame.height - y)
                apply(NSRect(x: frame.minX, y: frame.maxY - height, width: max(1, frame.width + x), height: height))
            }
        }
    }
}

struct GraphCanvasWindow<Content: View>: View {
    let folded: Bool
    let apply: (NSRect) -> Void
    let toggleFold, reset, close: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            if !folded { content() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 2) {
                if folded { AppIconButton(systemName: "plus", label: "展开 Graph", action: toggleFold) }
                GraphCanvasWindowHandle(kind: .move, apply: apply)
                    .frame(width: AppDesign.Metric.iconButtonSize, height: AppDesign.Metric.iconButtonSize)
                AppIconButton(systemName: "xmark", label: "关闭 Graph", action: close)
            }
            .padding(2).background(.regularMaterial, in: .rect(cornerRadius: AppDesign.Radius.container))
            .contextMenu {
                Button(folded ? "展开 Graph" : "收起 Graph", action: toggleFold)
                Button("复位窗口位置", action: reset)
            }
            .padding(6)
        }
        .overlay(alignment: .bottomTrailing) {
            if !folded {
                GraphCanvasWindowHandle(kind: .resize, apply: apply)
                    .frame(width: AppDesign.Metric.iconButtonSize, height: AppDesign.Metric.iconButtonSize)
                    .background(.regularMaterial, in: .rect(cornerRadius: AppDesign.Radius.container)).padding(6)
            }
        }
        .clipShape(.rect(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.18)).allowsHitTesting(false))
        .workbenchFocusAppearance()
    }
}
