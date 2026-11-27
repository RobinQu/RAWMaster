import AppKit
import SwiftUI
import RAWMasterCore

struct LibraryCatalogView: View {
    @EnvironmentObject var model: AppModel
    private var imports: Bool { model.scope == .imports }
    private var query: Binding<String> { imports ? $model.importCatalogQuery : $model.sequenceCatalogQuery }
    private var anchor: Binding<String?> { imports ? $model.importCatalogAnchorID : $model.sequenceCatalogAnchorID }
    private var hasConditions: Bool {
        !query.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || (imports ? model.importCatalogStatus != .all : model.sequenceCatalogType != .all)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.catalogTitle).font(.system(size: 20, weight: .semibold))
                Spacer()
                Text(imports ? "\(model.importCatalogItems.count) 个导入会话" : "\(model.sequenceCatalogItems.count) 个拍摄序列")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            HStack(spacing: 12) {
                CatalogSearchField(text: query, focusRequest: model.catalogSearchFocusRequest,
                    placeholder: imports ? "搜索来源目录、项目或状态" : "搜索序列名称、项目或类型")
                    .frame(minWidth: 180).frame(height: 28).background(SearchInteractionRegion())
                if imports {
                    Picker("会话状态", selection: $model.importCatalogStatus) {
                        ForEach(ImportCatalogStatusFilter.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 132)
                } else {
                    Picker("序列类型", selection: $model.sequenceCatalogType) {
                        ForEach(SequenceCatalogType.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 132)
                }
                if hasConditions { Button("清除") { clearConditions() }.buttonStyle(.borderless) }
            }.controlSize(.small).padding(.horizontal, 20).padding(.bottom, 14)
            Divider()
            catalogGrid
        }.background(AppPalette.canvas)
            .accessibilityElement(children: .contain).accessibilityLabel(model.catalogTitle + "目录")
    }
    private var catalogGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if imports ? model.importCatalogItems.isEmpty : model.sequenceCatalogItems.isEmpty { emptyState }
                else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)], alignment: .leading, spacing: 18) {
                        if imports {
                            ForEach(model.importCatalogItems) { item in
                                CatalogCard(title: item.title, subtitle: item.session.projectName, timestamp: item.createdAt,
                                    detail: "\(item.captureCount) 次拍摄 · \(item.fileCount) 个文件", badge: item.statusTitle,
                                    symbol: item.isActive ? "tray.and.arrow.down" : "clock.arrow.circlepath", covers: item.coverAssets,
                                    selected: anchor.wrappedValue == item.id,
                                    select: { anchor.wrappedValue = item.id }, open: { model.openCatalogSession(id: item.id) })
                                    .id(item.id).contextMenu { SessionCatalogMenu(session: item.session) }
                            }
                        } else {
                            ForEach(model.sequenceCatalogItems) { item in
                                CatalogCard(title: item.title, subtitle: model.projects.first { $0.id == item.group.projectID }?.name ?? "项目", timestamp: item.capturedAt,
                                    detail: "\(item.captureCount) 次拍摄 · \(item.fileCount) 个文件", badge: item.group.kind,
                                    symbol: item.type == .timelapse ? "timelapse" : "square.stack.3d.up", covers: item.coverAssets,
                                    selected: anchor.wrappedValue == item.id,
                                    select: { anchor.wrappedValue = item.id }, open: { model.openCatalogSequence(id: item.id) },
                                    edit: { model.openCatalogGroupProperties(item.id) }, editEnabled: model.canOpenCatalogGroupProperties(item.id), editIdentifier: item.id)
                                    .id(item.id).contextMenu {
                                        Button("打开拍摄序列") { model.openCatalogSequence(id: item.id) }
                                        Button("编辑拍摄组…") { model.openCatalogGroupProperties(item.id) }.disabled(!model.canOpenCatalogGroupProperties(item.id))
                                        if model.isTimelapseGroup(item.group) {
                                            Button("合成延时视频…") { model.openCatalogSequence(id: item.id); model.openTimelapse(groupID: item.id) }
                                                .disabled(!model.canComposeTimelapse(groupID: item.id))
                                        }
                                    }
                            }
                        }
                    }.padding(20)
                }
            }.defaultScrollAnchor(.topLeading)
                .onAppear { restoreAnchor(proxy) }
                .onChange(of: model.scope) { restoreAnchor(proxy) }
        }
    }
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(hasConditions ? "没有匹配的结果" : (imports ? "尚无导入记录" : "尚无拍摄序列"),
                systemImage: hasConditions ? "magnifyingglass" : (imports ? "tray" : "square.stack.3d.up"))
                .font(.title3.weight(.semibold))
            Text(hasConditions ? "更改搜索内容或筛选条件，再试一次。" : (imports ? "创建导入会话，开始接入一次拍摄。" : "在项目照片网格中多选照片，可创建连拍、延时等拍摄序列。"))
                .font(.caption).foregroundStyle(.secondary)
            if hasConditions { Button("清除搜索与筛选") { clearConditions() } }
            else if imports { Button("创建导入会话…") { model.openImport() }.disabled(model.isBusy) }
            else { Button("浏览全部素材") { model.selectScope(.all) } }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(28)
    }
    private func clearConditions() {
        query.wrappedValue = ""
        if imports { model.importCatalogStatus = .all } else { model.sequenceCatalogType = .all }
    }
    private func restoreAnchor(_ proxy: ScrollViewProxy) {
        if let id = anchor.wrappedValue { DispatchQueue.main.async { proxy.scrollTo(id, anchor: .top) } }
    }
}

private struct CatalogCard: View {
    let title: String
    let subtitle: String
    let timestamp: Date?
    let detail: String
    let badge: String
    let symbol: String
    let covers: [AssetRecord]
    let selected: Bool
    let select: () -> Void
    let open: () -> Void
    var edit: (() -> Void)? = nil
    var editEnabled = true
    var editIdentifier = ""
    var body: some View {
        ZStack(alignment: .topTrailing) {
            interactiveCard
                .accessibilityElement(children: .ignore).accessibilityLabel(accessibilityText)
                .accessibilityAddTraits(.isButton).accessibilityAction { open() }
                .help("单击选择，双击或按回车打开")
            if let edit {
                CatalogGroupEditButton(identifier: "group.catalog.properties." + editIdentifier, enabled: editEnabled, action: edit)
                    .frame(width: 28, height: 28).padding(8)
                    .background(AppPalette.overlay, in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel("编辑拍摄组属性").accessibilityAddTraits(.isButton)
                    .accessibilityAction { if editEnabled { edit() } }
            }
        }.accessibilityElement(children: .contain)
    }
    private var accessibilityText: String {
        var parts = [title, subtitle]
        if let timestamp { parts.append(timestamp.formatted(date: .complete, time: .standard)) }
        parts.append(contentsOf: [badge, detail])
        return parts.joined(separator: "，")
    }
    private var interactiveCard: some View {
        cardSurface.overlay { CatalogCardInput(onSelect: select, onOpen: open, excludesEditButton: edit != nil) }
    }
    private var cardSurface: some View {
        cardContent
            .background(selected ? AppPalette.accent.opacity(0.07) : AppPalette.panel, in: RoundedRectangle(cornerRadius: 8))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(selectionBorder)
    }
    private var selectionBorder: some View {
        RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AppPalette.accent : AppPalette.boundary, lineWidth: selected ? 2 : 1)
    }
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            CatalogCover(assets: covers, symbol: symbol).aspectRatio(1.5, contentMode: .fit).clipped()
            details
        }
    }
    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            if let timestamp {
                Text(timestamp.formatted(date: .abbreviated, time: .shortened)).font(.system(size: 10)).foregroundStyle(.secondary)
                    .lineLimit(1).help(timestamp.formatted(date: .complete, time: .standard))
            }
            HStack {
                Label(badge, systemImage: symbol).lineLimit(1)
                Spacer(minLength: 4)
                Text(detail).lineLimit(1).fixedSize()
            }.font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(12)
    }
}

private struct CatalogCover: View {
    let assets: [AssetRecord]
    let symbol: String
    var body: some View {
        GeometryReader { geometry in
            if assets.isEmpty {
                ZStack { AppPalette.thumbnailWell; Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(.secondary) }
            } else {
                let columns = assets.count == 1 ? 1 : 2
                let rows = assets.count <= 2 ? 1 : 2
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: columns), spacing: 2) {
                    ForEach(assets.prefix(4), id: \.id) { asset in
                        ThumbnailView(asset: asset).frame(height: (geometry.size.height - CGFloat(rows - 1) * 2) / CGFloat(rows))
                            .frame(maxWidth: .infinity).background(AppPalette.thumbnailWell).clipped()
                    }
                }
            }
        }.background(AppPalette.thumbnailWell).allowsHitTesting(false)
    }
}

struct SessionCatalogMenu: View {
    @EnvironmentObject var model: AppModel
    let session: ImportSession
    var includesOpen = true
    var includesRegroup = true
    var body: some View {
        if includesOpen { Button("打开导入会话") { model.openCatalogSession(id: session.id) } }
        Button("打开项目") { model.openSessionProject(sessionID: session.id) }.disabled(!model.canOpenSessionProject(sessionID: session.id))
        Divider()
        Button("继续接入") { model.continueIntake(sessionID: session.id) }.disabled(!model.canContinueIntake(sessionID: session.id))
        Button("重新扫描来源目录") { model.rescanSource(sessionID: session.id) }.disabled(!model.canRescanSource(sessionID: session.id))
            .help("发现并核验来源文件，保留已保存的人工处置；不会强制重新分组。")
        if includesRegroup {
            Button("重新扫描分组") { model.regroup(sessionID: session.id) }.disabled(model.regroupDisabledReason(sessionID: session.id) != nil)
        }
        if model.scope == .session, model.scopeID == session.id {
            Button("完成整批初筛…") { model.prepareCompletion() }.disabled(!model.canFinishSession(sessionID: session.id))
        }
        Divider()
        Button("重新定位原始来源…") { model.prepareRelocation(sessionID: session.id, role: .source) }.disabled(model.isBusy)
        if session.mode == .copy {
            Button("重新定位受管副本…") { model.prepareRelocation(sessionID: session.id, role: .managed) }.disabled(model.isBusy)
        }
        Button("在 Finder 中显示来源") { model.reveal(session.effectiveSourceURL.path) }
        let reports = model.relocationHistory.filter { $0.importSessionID == session.id }
        if !reports.isEmpty {
            Divider()
            Menu("找回原片记录") {
                ForEach(reports, id: \.id) { report in
                    Button(report.role.title + " · " + report.statusTitle) { model.reviewRelocation(report) }
                        .disabled(model.relocationIsRunning && model.relocationReport?.id != report.id)
                }
            }
        }
    }
}

private struct CatalogSearchField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let placeholder: String
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, focusRequest: focusRequest) }
    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.suppressStandardFocusRing()
        field.delegate = context.coordinator; field.target = context.coordinator; field.action = #selector(Coordinator.changed(_:))
        field.sendsSearchStringImmediately = true; field.sendsWholeSearchString = false
        return field
    }
    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        field.placeholderString = placeholder; field.setAccessibilityLabel(placeholder)
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { [weak field] in if let field { field.window?.makeFirstResponder(field); field.selectText(nil) } }
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var focusRequest: Int
        init(text: Binding<String>, focusRequest: Int) { self.text = text; self.focusRequest = focusRequest }
        @objc func changed(_ sender: NSSearchField) { text.wrappedValue = sender.stringValue }
        func controlTextDidChange(_ notification: Notification) { if let field = notification.object as? NSSearchField { changed(field) } }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            if command == #selector(NSResponder.cancelOperation(_:)) || command == #selector(NSResponder.insertNewline(_:)) {
                control.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}
struct CatalogCardInput: NSViewRepresentable {
    let onSelect: () -> Void
    let onOpen: () -> Void
    var excludesEditButton = false
    func makeNSView(context: Context) -> InputView {
        let view = InputView(); view.setAccessibilityElement(false); return view
    }
    func updateNSView(_ view: InputView, context: Context) { view.onSelect = onSelect; view.onOpen = onOpen; view.excludesEditButton = excludesEditButton }
    final class InputView: NSView {
        var onSelect: (() -> Void)?
        var onOpen: (() -> Void)?
        var excludesEditButton = false
        func isEditButtonPoint(_ point: NSPoint) -> Bool {
            let local = convert(point, from: superview)
            let top = isFlipped ? bounds.minY : bounds.maxY - 44
            return excludesEditButton && CGRect(x: bounds.maxX - 44, y: top, width: 44, height: 44).contains(local)
        }
        override var acceptsFirstResponder: Bool { true }
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? {
            if isEditButtonPoint(point) { return nil }
            guard CardInputView.captures(NSApp.currentEvent) else { return nil }
            return super.hitTest(point)
        }
        override func mouseDown(with event: NSEvent) {
            guard event.type == .leftMouseDown, !event.modifierFlags.contains(.control) else { return }
            window?.makeFirstResponder(self)
            onSelect?()
            if event.clickCount == 2 { onOpen?() }
        }
        override func keyDown(with event: NSEvent) {
            if event.keyCode == 36 || event.keyCode == 76 { onOpen?() }
            else { super.keyDown(with: event) }
        }
        override func mouseUp(with event: NSEvent) {}
    }
}

/// A separate native control is above the whole-card input and has its own AX node.
struct CatalogGroupEditButton: NSViewRepresentable {
    let identifier: String
    let enabled: Bool
    let action: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(action: action) }
    func makeNSView(context: Context) -> NSButton {
        let button = CatalogPropertiesNativeButton(image: NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "编辑拍摄组属性")!, target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .recessed; button.isBordered = false
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.setAccessibilityLabel("编辑拍摄组属性"); button.toolTip = "编辑拍摄组名称、用途和结构保护"
        return button
    }
    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.action = action; view.identifier = NSUserInterfaceItemIdentifier(identifier)
        view.isEnabled = enabled
    }
    @MainActor final class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

private final class CatalogPropertiesNativeButton: NSButton {
    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        // The action navigates away from this card. Report that the accepted
        // press was delivered even when navigation immediately disables it.
        performClick(nil)
        return true
    }
}
