import AppKit
import SwiftUI

/// AppKit owns title dragging, close and edge resizing. The titlebar menu also exposes
/// geometry to keyboard and VoiceOver users without intercepting navigation in the canvas.
final class GraphWindowMenu: NSPopUpButton {
    enum Adjustment { case move, resize }
    private(set) var adjustment: Adjustment?
    private let apply: (Adjustment, CGFloat, CGFloat) -> Void
    private let fold: () -> Void
    private let reset: () -> Void
    private var foldItem: NSMenuItem?
    private let helpText = "移动、调整大小、收起或复位图窗"

    init(apply: @escaping (Adjustment, CGFloat, CGFloat) -> Void, fold: @escaping () -> Void, reset: @escaping () -> Void) {
        self.apply = apply
        self.fold = fold
        self.reset = reset
        super.init(frame: NSRect(x: 0, y: 0, width: AppDesign.Metric.iconButtonSize + AppDesign.Spacing.inline,
                                 height: AppDesign.Metric.compactRowHeight), pullsDown: true)
        isBordered = false
        imagePosition = .imageOnly
        (cell as? NSPopUpButtonCell)?.arrowPosition = .noArrow
        suppressStandardFocusRing()
        addItem(withTitle: "")
        item(at: 0)?.image = NSImage(systemSymbolName: "ellipsis", accessibilityDescription: nil)
        menu?.autoenablesItems = false
        for (title, selector) in [("移动窗口…", #selector(moveWindow)), ("调整大小…", #selector(resizeWindow)),
                                  ("收起窗口", #selector(foldWindow)), ("复位窗口", #selector(resetWindow))] {
            let entry = NSMenuItem(title: title, action: selector, keyEquivalent: "")
            entry.target = self
            menu?.addItem(entry)
            if selector == #selector(foldWindow) { foldItem = entry }
        }
        toolTip = "图窗操作"
        setAccessibilityLabel("图窗操作")
        cell?.setAccessibilityLabel("图窗操作")
        setAccessibilityIdentifier("scene.graph.window.menu")
        cell?.setAccessibilityIdentifier("scene.graph.window.menu")
        setAccessibilityHelp(helpText)
    }

    required init?(coder: NSCoder) { nil }
    func setFolded(_ folded: Bool) { foldItem?.title = folded ? "展开窗口" : "收起窗口" }

    @objc private func moveWindow() { begin(.move) }
    @objc private func resizeWindow() { begin(.resize) }
    @objc private func foldWindow() { endAdjustment(); fold() }
    @objc private func resetWindow() { endAdjustment(); reset() }

    private func begin(_ adjustment: Adjustment) {
        self.adjustment = adjustment
        window?.makeFirstResponder(self)
        let text = adjustment == .move ? "方向键移动窗口，回车或 Escape 完成" : "方向键调整大小，回车或 Escape 完成"
        setAccessibilityHelp(text)
        NSAccessibility.post(element: self, notification: .announcementRequested,
            userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        needsDisplay = true
    }

    func endAdjustment() {
        guard adjustment != nil else { return }
        adjustment = nil
        setAccessibilityHelp(helpText)
        needsDisplay = true
    }

    func handleAdjustmentKey(_ event: NSEvent) -> Bool {
        guard let adjustment, event.type == .keyDown else { return false }
        switch event.keyCode {
        case 123: apply(adjustment, -16, 0)
        case 124: apply(adjustment, 16, 0)
        case 125: apply(adjustment, 0, -16)
        case 126: apply(adjustment, 0, 16)
        case 36, 76, 53: endAdjustment()
        default: endAdjustment(); return false
        }
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if adjustment != nil || window?.firstResponder === self {
            NSColor.secondaryLabelColor.setFill()
            NSRect(x: bounds.minX + 6, y: isFlipped ? bounds.maxY - 3 : bounds.minY + 1,
                   width: max(0, bounds.width - 12), height: 2).fill()
        }
    }
}

private struct GraphPanelBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct GraphCanvasWindow<Content: View>: View {
    let folded: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            if !folded { content() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            AppPalette.panel.opacity(0.16)
                .floatingSelectionSurface(cornerRadius: 0)
                .background { GraphPanelBackdrop() }
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .workbenchFocusAppearance()
    }
}

struct GraphCanvasGrid: View {
    var scale: CGFloat = 1
    var offset: CGSize = .zero

    var body: some View {
        Canvas { context, size in
            let step = max(9, 20 * scale * (scale < 0.55 ? 4 : 1))
            let x = offset.width.truncatingRemainder(dividingBy: step)
            let y = offset.height.truncatingRemainder(dividingBy: step)
            var grid = Path()
            for column in stride(from: x, to: size.width, by: step) {
                grid.move(to: CGPoint(x: column, y: 0)); grid.addLine(to: CGPoint(x: column, y: size.height))
            }
            for row in stride(from: y, to: size.height, by: step) {
                grid.move(to: CGPoint(x: 0, y: row)); grid.addLine(to: CGPoint(x: size.width, y: row))
            }
            context.stroke(grid, with: .color(.primary.opacity(0.12)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

struct GraphActionMenu<Commands: View>: View {
    let title: String
    var stretches = false
    @ViewBuilder let commands: () -> Commands

    var body: some View {
        Menu(content: commands) {
            HStack(spacing: AppDesign.Spacing.inline) {
                Text(title).lineLimit(1)
                if stretches { Spacer(minLength: 0) }
                Image(systemName: "chevron.down").imageScale(.small).accessibilityHidden(true)
            }
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(AppFlatButtonStyle(stretches: stretches))
        .accessibilityLabel(title)
    }
}
