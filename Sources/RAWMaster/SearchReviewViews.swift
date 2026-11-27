import AppKit
import SwiftUI
import RAWMasterCore

enum ProjectSearchCondition: Hashable {
    case filename, dates, camera, rating, tag(String), decision, availability, review, colorLabel
}
struct ProjectSearchChip: Identifiable {
    var id: ProjectSearchCondition { condition }
    let condition: ProjectSearchCondition
    let title: String
    let detail: String
}

/// A geometry marker for non-modal search controls. It never intercepts input.
struct SearchInteractionRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> SearchRegionView { SearchRegionView() }
    func updateNSView(_ nsView: SearchRegionView, context: Context) {}
}
final class SearchRegionView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); SearchInteractionRegions.register(self) }
}
@MainActor enum SearchInteractionRegions {
    private static let regions = NSHashTable<SearchRegionView>.weakObjects()
    static func register(_ view: SearchRegionView) { regions.add(view) }
    static func contains(window: NSWindow, point: NSPoint) -> Bool {
        regions.allObjects.contains { view in
            view.window === window && !view.isHiddenOrHasHiddenAncestor && view.bounds.contains(view.convert(point, from: nil))
        }
    }
    static func containsResponder(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder as? NSView, responder !== window.contentView else { return false }
        let point = responder.convert(NSPoint(x: responder.bounds.midX, y: responder.bounds.midY), to: nil)
        return contains(window: window, point: point)
    }
}

struct ProjectToolbarSearchField: NSViewRepresentable {
    @EnvironmentObject var model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> SearchField {
        let field = SearchField()
        field.suppressStandardFocusRing()
        field.placeholderString = "搜索文件名 · 点击添加筛选条件"
        field.setAccessibilityLabel("搜索文件名")
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.sendsSearchStringImmediately = true
        field.sendsWholeSearchString = false
        field.delegate = context.coordinator
        field.target = context.coordinator; field.action = #selector(Coordinator.changed(_:))
        field.onActivate = { [weak coordinator = context.coordinator] in coordinator?.activate() }
        return field
    }
    func updateNSView(_ field: SearchField, context: Context) {
        if field.stringValue != model.effectiveSearchQuery.filename { field.stringValue = model.effectiveSearchQuery.filename }
        if context.coordinator.focusRequest != model.searchFocusRequest {
            context.coordinator.focusRequest = model.searchFocusRequest
            field.requestFocus()
        }
    }
    final class SearchField: NSSearchField {
        var onActivate: (() -> Void)?
        private var needsSearchFocus = false
        override func mouseDown(with event: NSEvent) { onActivate?(); super.mouseDown(with: event) }
        func requestFocus() {
            needsSearchFocus = true
            DispatchQueue.main.async { [weak self] in self?.resolveFocus() }
        }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); resolveFocus() }
        private func resolveFocus() {
            guard needsSearchFocus, let window else { return }
            needsSearchFocus = false; window.makeFirstResponder(self); selectText(nil)
        }
    }
    @MainActor final class Coordinator: NSObject, NSSearchFieldDelegate {
        let model: AppModel
        var focusRequest: Int
        init(model: AppModel) { self.model = model; focusRequest = model.searchFocusRequest }
        func activate() {
            guard model.canActivateProjectSearch else { return }
            if !model.showSearchFilters { model.toggleSearchFilters() }
            model.searchControlsOwnKeyboard = true
        }
        @objc func changed(_ sender: NSSearchField) {
            model.searchControlsOwnKeyboard = true
            _ = model.editSearchQuery { $0.filename = sender.stringValue }
        }
        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSSearchField { changed(field) }
        }
        func controlTextDidBeginEditing(_ obj: Notification) { activate() }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                model.hideSearchField(); control.window?.makeFirstResponder(nil); return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                model.searchControlsOwnKeyboard = false; control.window?.makeFirstResponder(nil); return true
            }
            return false
        }
    }
}

/// Finder-style scope, search and additive criteria remain together above the grid.
struct ProjectSearchHeader: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ProjectToolbarSearchField().frame(minWidth: 160, maxWidth: .infinity).frame(height: 28)
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { model.toggleSearchFilters() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease")
                        Text(model.hasSearchConditions ? "条件 \(model.searchConditionChips.count)" : "条件")
                        Image(systemName: model.showSearchFilters ? "chevron.up" : "chevron.down").font(.system(size: 8, weight: .semibold))
                    }.font(.caption).padding(.horizontal, 9).frame(height: 26)
                        .background(model.showSearchFilters ? AppPalette.accent.opacity(0.12) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain).help("展开或收起筛选条件，保留当前搜索")
                    .accessibilityLabel(model.showSearchFilters ? "收起筛选条件" : "展开筛选条件")
            }.padding(.horizontal, 18).padding(.vertical, 8)
            if model.hasSearchConditions {
                ProjectSearchChips().padding(.horizontal, 18).padding(.bottom, 8)
            }
            if model.showSearchFilters {
                ProjectSearchFiltersPanel().id(model.searchScopeIdentity)
                    .frame(height: 220)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }.background(AppPalette.panel).background(SearchInteractionRegion())
            .accessibilityElement(children: .contain).accessibilityLabel("搜索与筛选")
    }
}

private enum SearchCriterionStyle {
    static func icon(_ condition: ProjectSearchCondition) -> String {
        switch condition {
        case .filename: "doc.text.magnifyingglass"
        case .dates: "calendar"
        case .camera: "camera"
        case .rating: "star.fill"
        case .tag: "tag"
        case .colorLabel: "circle.fill"
        case .decision: "flag.fill"
        case .availability: "externaldrive"
        case .review: "checkmark.circle"
        }
    }
    static func color(_ condition: ProjectSearchCondition) -> Color {
        switch condition {
        case .filename: AppPalette.accent
        case .dates: .indigo
        case .camera: .teal
        case .rating: .orange
        case .tag: .secondary
        case .colorLabel: .orange
        case .decision: .purple
        case .availability: .brown
        case .review: .green
        }
    }

}

struct ProjectSearchChips: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(model.searchConditionChips) { chip in
                        let color = chip.condition == .colorLabel ? (model.effectiveSearchQuery.colorLabel?.color ?? .secondary) : SearchCriterionStyle.color(chip.condition)
                        Button { model.removeSearchCondition(chip.condition) } label: {
                            HStack(spacing: 5) {
                                Image(systemName: SearchCriterionStyle.icon(chip.condition)).foregroundStyle(color)
                                Text(chip.title).lineLimit(1).truncationMode(.middle)
                                Image(systemName: "xmark").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
                            }.font(.caption2).padding(.horizontal, 8).frame(height: 23)
                                .background(color.opacity(0.10), in: Capsule())
                                .overlay(Capsule().strokeBorder(color.opacity(0.20), lineWidth: 0.5))
                        }.buttonStyle(.plain).frame(maxWidth: 165).fixedSize(horizontal: false, vertical: true)
                            .help(chip.detail + "；点击移除此条件")
                            .accessibilityLabel("移除筛选：" + chip.detail)
                    }
                }
            }.frame(height: 25)
            Button("清除") { model.clearProjectSearch() }.buttonStyle(.plain).font(.caption2).foregroundStyle(.secondary)
                .help("清除全部搜索条件").accessibilityLabel("清除全部搜索条件")
        }.background(SearchInteractionRegion())
    }
}

struct ProjectSearchFiltersPanel: View {
    @EnvironmentObject var model: AppModel
    @State private var tagDraft = ""
    @FocusState private var tagFocused: Bool
    private var query: ProjectSearchQuery { model.effectiveSearchQuery }
    private var zone: TimeZone { TimeZone(identifier: query.timeZoneIdentifier) ?? .current }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = zone; return value }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Label("搜索范围", systemImage: "folder").foregroundStyle(.secondary)
                if model.scope == .group { Text("当前拍摄组").fontWeight(.medium) }
                else {
                    Picker("搜索范围", selection: Binding(get: { model.scope == .all ? "all" : model.scopeID }, set: { model.selectSearchScope($0 == "all" ? nil : $0) })) {
                        Text("全部项目").tag("all")
                        if let id = model.searchPanelProjectID, let project = model.projects.first(where: { $0.id == id }) {
                            Text(project.name).tag(id)
                        }
                    }.labelsHidden().pickerStyle(.menu).lineLimit(1).truncationMode(.middle)
                        .frame(minWidth: 80, maxWidth: 200)
                        .help(model.scope == .all ? "全部项目" : model.scopeTitle)
                }
                Spacer(minLength: 0)
                Text("同时满足以下条件").foregroundStyle(.tertiary)
            }.font(.caption).padding(.horizontal, 18).padding(.vertical, 7)
            if let message = model.searchValidationMessage {
                Label(message + "；仍显示最后有效结果。", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(AppPalette.warning).padding(.horizontal, 18).padding(.bottom, 6)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    section("决定与审阅", icon: "flag", color: .purple) {
                        Picker("决定", selection: field(\.decision, fallback: nil)) {
                            Text("全部决定").tag(Optional<Decision>.none)
                            ForEach(Decision.allCases, id: \.rawValue) { Text($0.title).tag(Optional($0)) }
                        }
                        Picker("审阅", selection: field(\.review)) {
                            Text("全部").tag(ReviewFilter.all); Text("已审").tag(ReviewFilter.reviewed); Text("未审").tag(ReviewFilter.unreviewed)
                        }
                        HStack {
                            ratingPicker("最低", keyPath: \.minimumRating)
                            ratingPicker("最高", keyPath: \.maximumRating)
                        }
                    }
                    section("颜色与文字标签", icon: "tag.fill", color: .orange) {
                        Picker("颜色标签", selection: field(\.colorLabel, fallback: nil)) {
                            Text("全部颜色").tag(Optional<PhotoColorLabel>.none)
                            ForEach(PhotoColorLabel.allCases, id: \.rawValue) { label in
                                ColorLabelMenuLabel(label: label).tag(Optional(label))
                            }
                        }
                        HStack {
                            TextField("添加标签后按回车", text: $tagDraft).textFieldStyle(.roundedBorder)
                                .focused($tagFocused).onSubmit { commitTagDraft() }
                                .onChange(of: tagDraft) { value in
                                    if value.contains(where: { ",，;；".contains($0) }) { commitTagDraft() }
                                }
                            Picker("标签匹配", selection: field(\.tagMatch)) {
                                Text("全部").tag(SearchTagMatch.all); Text("任一").tag(SearchTagMatch.any)
                            }.labelsHidden().frame(width: 68)
                        }
                        let suggestions = model.tagSuggestions(for: tagDraft).filter { tag in !query.tags.contains { TagText.key($0) == TagText.key(tag) } }
                        if !suggestions.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 68), spacing: 6)], alignment: .leading, spacing: 6) {
                                ForEach(Array(suggestions.prefix(6)), id: \.self) { tag in
                                    Button { addTags([tag]); tagDraft = "" } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "tag").font(.system(size: 8)).foregroundStyle(.secondary)
                                            Text(tag).lineLimit(1)
                                        }.font(.caption2).padding(.horizontal, 6).padding(.vertical, 4)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 4))
                                    }.buttonStyle(.plain).help("添加标签筛选：" + tag)
                                }
                            }
                        } else { Text(query.tags.isEmpty ? "输入已有或自定义标签" : "已选标签显示在搜索栏下方").font(.caption2).foregroundStyle(.tertiary) }
                    }
                    section("相机与文件", icon: "camera", color: .teal) {
                        Picker("相机", selection: field(\.camera, fallback: nil)) {
                            Text("全部机型").tag(Optional<String>.none)
                            ForEach(model.availableSearchCameras, id: \.self) { Text($0).tag(Optional($0)) }
                        }
                        Picker("可用性", selection: field(\.availability, fallback: nil)) {
                            Text("全部状态").tag(Optional<AssetAvailability>.none)
                            Text("在线").tag(Optional(AssetAvailability.available))
                            Text("缺失 / 离线").tag(Optional(AssetAvailability.missing))
                            Text("内容变化").tag(Optional(AssetAvailability.changed))
                        }
                    }
                    section("拍摄日期", icon: "calendar", color: .indigo) {
                        HStack {
                            Toggle("从", isOn: Binding(get: { query.capturedFrom != nil }, set: { enabled in
                                changeDates(start: enabled ? (endDay ?? Date()) : nil, end: endDay)
                            })).toggleStyle(.checkbox).frame(width: 44, alignment: .leading)
                            if let start = query.capturedFrom {
                                DatePicker("起始日期", selection: Binding(get: { start }, set: { changeDates(start: $0, end: endDay) }), displayedComponents: .date).labelsHidden().datePickerStyle(.field).controlSize(.small)
                            } else { Text("不限起始日期").foregroundStyle(.tertiary) }
                        }
                        HStack {
                            Toggle("至", isOn: Binding(get: { query.capturedBefore != nil }, set: { enabled in
                                changeDates(start: query.capturedFrom, end: enabled ? (query.capturedFrom ?? Date()) : nil)
                            })).toggleStyle(.checkbox).frame(width: 44, alignment: .leading)
                            if let end = endDay {
                                DatePicker("结束日期", selection: Binding(get: { end }, set: { changeDates(start: query.capturedFrom, end: $0) }), displayedComponents: .date).labelsHidden().datePickerStyle(.field).controlSize(.small)
                            } else { Text("不限结束日期").foregroundStyle(.tertiary) }
                        }
                        Text("包含起止当天 · \(query.timeZoneIdentifier)").font(.caption2).foregroundStyle(.secondary)
                    }
                }.controlSize(.small).font(.caption).padding(.horizontal, 18).padding(.bottom, 12)
            }
        }.background(Color.primary.opacity(0.025)).background(SearchInteractionRegion())
            .environment(\.timeZone, zone)
            .onChange(of: tagFocused) { if $0 { model.searchControlsOwnKeyboard = true } }
            .onChange(of: model.effectiveSearchQuery) { _ in tagDraft = "" }
            .onExitCommand { model.hideSearchFilters() }
            .accessibilityElement(children: .contain).accessibilityLabel("即时筛选面板")
    }
    private var endDay: Date? { query.capturedBefore.flatMap { calendar.date(byAdding: .day, value: -1, to: $0) } }
    private func field<Value>(_ keyPath: WritableKeyPath<ProjectSearchQuery, Value>) -> Binding<Value> {
        Binding(get: { query[keyPath: keyPath] }, set: { value in model.editSearchQuery { $0[keyPath: keyPath] = value } })
    }
    private func field<Value>(_ keyPath: WritableKeyPath<ProjectSearchQuery, Value?>, fallback: Value?) -> Binding<Value?> { field(keyPath) }
    @ViewBuilder private func section<Content: View>(_ title: String, icon: String, color: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon).font(.caption.weight(.medium)).foregroundStyle(color)
            content()
        }.padding(10).frame(maxWidth: .infinity, alignment: .topLeading)
            .background(AppPalette.panel, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(AppPalette.boundary.opacity(0.6), lineWidth: 0.5))
    }
    private func ratingPicker(_ title: String, keyPath: WritableKeyPath<ProjectSearchQuery, Int?>) -> some View {
        Picker(title, selection: field(keyPath, fallback: nil)) {
            Text("不限").tag(Optional<Int>.none)
            ForEach(0...5, id: \.self) { Text("\($0) ★").tag(Optional($0)) }
        }
    }
    private func changeDates(start: Date?, end: Date?) {
        model.editSearchQuery { try $0.setDateRange(startDay: start, endDay: end, timeZone: zone) }
    }
    private func addTags(_ values: [String]) {
        model.editSearchQuery { $0.tags = try TagText.normalized($0.tags + values) }
    }
    private func commitTagDraft() {
        let values = tagDraft.split(whereSeparator: { ",，;；".contains($0) }).map(String.init)
        guard !values.isEmpty else { return }
        addTags(values)
        if model.searchValidationMessage == nil { tagDraft = "" }
    }
}

struct ProjectReviewActions: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Menu("审阅") {
            Button("将所选标记已审") { model.markSelectedReviewed(true) }
            Button("将所选标记未审") { model.markSelectedReviewed(false) }
            Divider()
            Text("浏览不标记已审；评分或决定会标记。撤销决定保留已审记录。")
        }.disabled(model.actionAssetIDs.isEmpty)
    }
}

struct BatchTagEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var text = ""
    @State private var operation: TagMutationMode = .add
    var body: some View {
        let summary = model.selectedTagSummary
        VStack(alignment: .leading, spacing: 8) {
            Text(model.actionScopeLabel).font(.caption).foregroundStyle(.secondary)
            Text("共有：" + (summary.common.isEmpty ? "无" : summary.common.joined(separator: "、"))).font(.caption)
            if !summary.mixed.isEmpty { Text("部分文件：" + summary.mixed.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
            Picker("标签操作", selection: $operation) { ForEach(TagMutationMode.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu)
            TextField(operation == .replace ? "替换后的全部标签；留空表示清空" : "以逗号分隔标签", text: $text)
                .textFieldStyle(.roundedBorder).font(.caption)
            if !model.tagVocabulary.isEmpty {
                ScrollView(.horizontal) { HStack { ForEach(model.tagSuggestions(for: text), id: \.self) { tag in Button(tag) { text = model.completingTag(text, with: tag) }.buttonStyle(.bordered).controlSize(.mini) } } }
            }
            if operation == .replace { Text("替换会移除所选文件的其他标签，请先核对逐文件变化。").font(.caption).foregroundStyle(AppPalette.warning) }
            HStack {
                Button("预览标签变化…") { model.prepareTagMutation(text: text, mode: operation) }.disabled(model.actionAssetIDs.isEmpty)
                Spacer()
                Button("操作历史…") { model.showTagHistory = true }
            }.controlSize(.small)
        }
    }
}

struct BatchTagPreviewSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(model.tagPreview?.mode.title ?? "")标签预览").font(.title2.weight(.semibold))
            if let preview = model.tagPreview {
                Text("范围：\(preview.assetIDs.count) 个文件 · \(preview.changedAssetIDs.count) 个文件会改变").font(.headline)
                Text("共有标签：" + (preview.commonTags.isEmpty ? "无" : preview.commonTags.joined(separator: "、"))).font(.caption)
                if !preview.mixedTags.isEmpty { Text("混合标签：" + preview.mixedTags.joined(separator: "、")).font(.caption).foregroundStyle(.secondary) }
                if preview.mode == .replace { Label(preview.tags.isEmpty ? "将清空所选文件的全部标签" : "将替换所选文件的全部标签", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(AppPalette.warning) }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(preview.assetIDs, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(model.assetFilename(id)).font(.caption.weight(.semibold))
                                Text("原：" + ((preview.before[id] ?? []).isEmpty ? "无" : (preview.before[id] ?? []).joined(separator: "、"))).font(.caption).foregroundStyle(.secondary)
                                Text("后：" + ((preview.after[id] ?? []).isEmpty ? "无" : (preview.after[id] ?? []).joined(separator: "、"))).font(.caption)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Divider()
                        }
                    }
                }.frame(maxHeight: 360)
                if preview.changedAssetIDs.isEmpty { Text("没有标签需要改变。").font(.caption).foregroundStyle(.secondary) }
                if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning) }
                HStack {
                    Button("取消") { model.tagPreview = nil; dismiss() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("应用到 \(preview.changedAssetIDs.count) 个文件") { _ = model.applyTagMutation() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(preview.changedAssetIDs.isEmpty)
                }
            } else { Text("当前范围已变化，请关闭并重新预览。").foregroundStyle(AppPalette.warning); Button("关闭") { dismiss() } }
        }.padding(24).frame(width: 650)
    }
}

struct TagOperationHistorySheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("标签操作历史").font(.title2.weight(.semibold))
            Text("恢复只改变该次标签操作；有后续标签修改时会报告冲突。").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.scopedTagCommands) { command in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(command.preview.mode.title) · \(command.preview.changedAssetIDs.count) 个文件").font(.headline)
                                Text(model.tagCommandScopeLabel(command)).font(.caption).foregroundStyle(.secondary)
                                Text(command.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                Text(command.preview.tags.joined(separator: "、")).font(.caption)
                            }
                            Spacer()
                            Button(command.restored ? "已恢复" : "恢复此操作") { model.restoreTagCommand(command.id) }.disabled(command.restored)
                        }
                        Divider()
                    }
                    if model.scopedTagCommands.isEmpty { Text("当前范围暂无完整标签操作。").foregroundStyle(.secondary) }
                }
            }.frame(maxHeight: 420)
            if let error = model.errorMessage { Text(error).font(.caption).foregroundStyle(AppPalette.warning) }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 650)
    }
}
