import AppKit
import SwiftUI

@main
struct RAWMasterApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var appearance = AppearanceController()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var appDelegate
    var body: some Scene {
        WindowGroup("RAWMaster") {
            WorkbenchView().environmentObject(model)
                .preferredColorScheme(appearance.preference.preferredColorScheme)
                .environment(\.resolvedAppAppearance, appearance.resolved)
                .focusedSceneValue(\.workbenchModel, model)
                .frame(minWidth: 1100, minHeight: 720)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.saveBrowse(); model.cancelJob() }
        }
        .defaultSize(width: 1480, height: 940)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("接入素材…") { model.openImport() }.keyboardShortcut("i", modifiers: .command).disabled(model.isBusy)
                Button("交付精选原片…") { model.showExport = true }.keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.scopedAssets.isEmpty || model.isBusy)
            }
            WorkbenchUndoCommands()
            CommandMenu("选片") {
                Button("保留 P") { model.decide(.keep) }.disabled(model.selectedIDs.isEmpty)
                Button("排除 X") { model.decide(.reject) }.disabled(model.selectedIDs.isEmpty)
                Button("清除决定 U") { model.decide(.undecided) }.disabled(model.selectedIDs.isEmpty)
                Divider()
                ForEach(0..<6) { rating in Button("\(rating) 星") { model.decide(rating: rating) }.disabled(model.selectedIDs.isEmpty) }
                Divider()
                Button("建立手动拍摄组…") { model.editGroup() }.disabled(model.selectedIDs.isEmpty)
                Toggle("决定后自动前进", isOn: $model.autoAdvance).onChange(of: model.autoAdvance) { model.saveBrowse() }
            }
            CommandMenu("浏览") {
                Button("网格 G") { model.setMode(.grid) }
                Button("单张 E") { model.setMode(.single) }
                Button("比较 C") { model.setMode(.compare) }
                Divider()
                Button("适合窗口 / 原始像素 Z") { model.actualPixels.toggle() }
                Button("显示 / 收起信息栏 Tab") { model.showInspector.toggle() }
                Button("刷新文件可用性") { model.refreshAvailability() }
            }
        }
        Settings { AppearanceSettingsView(appearance: appearance) }
    }
}

final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { InteractionTrace.shared.install(); NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationWillTerminate(_ notification: Notification) { InteractionTrace.shared.flush() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct KeyboardMonitor: NSViewRepresentable {
    var handler: (NSEvent) -> Bool
    func makeCoordinator() -> Coordinator { Coordinator(handler: handler) }
    func makeNSView(context: Context) -> NSView { let view = WorkbenchKeyAnchor(); context.coordinator.view = view; context.coordinator.install(); return view }
    func updateNSView(_ nsView: NSView, context: Context) { context.coordinator.handler = handler }
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) { coordinator.remove() }
    final class Coordinator {
        var handler: (NSEvent) -> Bool
        var monitor: Any?
        weak var view: NSView?
        init(handler: @escaping (NSEvent) -> Bool) { self.handler = handler }
        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.shouldHandle(event, keyWindow: NSApp.keyWindow, isActive: NSApp.isActive) else { return event }
                return self.handler(event) ? nil : event
            }
        }
        func shouldHandle(_ event: NSEvent, keyWindow: NSWindow?, isActive: Bool) -> Bool {
            guard isActive, let ownWindow = view?.window, keyWindow === ownWindow,
                  event.window === ownWindow, ownWindow.attachedSheet == nil else { return false }
            return !(ownWindow.firstResponder is NSTextView) && !(ownWindow.firstResponder is NSTextField)
        }
        func remove() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
        deinit { remove() }
    }
}
