import AppKit
import SwiftUI

struct WorkbenchLibraryTitle: NSViewRepresentable {
    let name: String
    let directory: URL
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> TitleButton {
        let button = TitleButton(title: name, target: nil, action: nil)
        button.isBordered = false
        button.alignment = .left
        button.font = .systemFont(ofSize: 13, weight: .semibold)
        button.cell?.lineBreakMode = .byTruncatingMiddle
        button.target = button
        button.action = #selector(TitleButton.showPath(_:))
        button.setAccessibilityIdentifier("library.window.title")
        return button
    }

    func updateNSView(_ button: TitleButton, context: Context) {
        button.title = name
        button.directory = directory
        button.toolTip = directory.path
        button.isEnabled = isEnabled
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TitleButton, context: Context) -> CGSize? {
        let natural = nsView.intrinsicContentSize
        return CGSize(width: min(natural.width, proposal.width ?? 200, 200), height: max(natural.height, 26))
    }

    static func dismantleNSView(_ button: TitleButton, coordinator: ()) {
        button.removeContextMenuMonitor()
    }

    final class TitleButton: NSButton {
        var directory: URL?
        private var contextMenuMonitor: Any?

        override func accessibilityTitle() -> String? { title }
        override func accessibilityLabel() -> String? { title }
        override func accessibilityHelp() -> String? { "显示资料库路径" }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeContextMenuMonitor()
            guard window != nil else { return }
            // The unified toolbar handles right-clicks before its embedded controls receive them.
            contextMenuMonitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
                let handled = MainActor.assumeIsolated { self?.openContextMenu(for: event) == true }
                return handled ? nil : event
            }
        }

        fileprivate func removeContextMenuMonitor() {
            if let contextMenuMonitor { NSEvent.removeMonitor(contextMenuMonitor) }
            contextMenuMonitor = nil
        }

        private func openContextMenu(for event: NSEvent) -> Bool {
            guard isEnabled, !isHiddenOrHasHiddenAncestor, let window, event.window === window,
                  window.attachedSheet == nil, NSApp.modalWindow == nil,
                  visibleRect.contains(convert(event.locationInWindow, from: nil)), let menu = pathMenu() else { return false }
            NSMenu.popUpContextMenu(menu, with: event, for: self)
            return true
        }

        override func keyDown(with event: NSEvent) {
            if isEnabled, [36, 76].contains(event.keyCode), !event.modifierFlags.contains(.command) {
                showPath(self)
            } else {
                super.keyDown(with: event)
            }
        }

        @objc func showPath(_ sender: Any?) {
            guard isEnabled else { return }
            pathMenu()?.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY), in: self)
        }

        func pathMenu() -> NSMenu? {
            guard let directory else { return nil }
            let menu = NSMenu()
            let volume = try? directory.resourceValues(forKeys: [.volumeURLKey]).volume
            var location = directory
            while true {
                let isLibrary = location == directory
                let name = isLibrary ? title : FileManager.default.displayName(atPath: location.path)
                let entry = NSMenuItem(title: name, action: #selector(reveal(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = location
                entry.toolTip = location.path
                let icon = (isLibrary ? LibraryFolderIcon.image : nil) ?? NSWorkspace.shared.icon(forFile: location.path)
                let thumbnail = icon.copy() as? NSImage
                thumbnail?.size = NSSize(width: 16, height: 16)
                entry.image = thumbnail
                menu.addItem(entry)
                let parent = location.deletingLastPathComponent()
                if location.path == volume?.path || parent.path == location.path || parent.path.isEmpty { break }
                location = parent
            }
            menu.addItem(.separator())
            let copy = NSMenuItem(title: "拷贝资料库路径", action: #selector(copyPath(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = directory
            menu.addItem(copy)
            return menu
        }

        @objc private func reveal(_ item: NSMenuItem) {
            if let location = item.representedObject as? URL {
                NSWorkspace.shared.activateFileViewerSelecting([location])
            }
        }

        @objc private func copyPath(_ item: NSMenuItem) {
            guard let location = item.representedObject as? URL else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(location.path, forType: .string)
        }
    }
}
