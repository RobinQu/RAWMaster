import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore
import RAWMasterImaging
import RAWMasterAI

private let canvasColor = AppPalette.canvas
private let panelColor = AppPalette.panel

struct WorkbenchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @State private var sidebarBeforeEditing: Bool?
    @State private var appearanceBeforeEditing: NSAppearance?
    @State private var showFluxFirstRun = false
    private var workbenchSurface: some View {
        VStack(spacing: 0) {
            if model.exportWorkspacePresented {
                ExportWorkspace()
            } else if model.isNativeEditing, let editing = model.editing {
                EditingWorkspace(editing: editing)
                    .environment(\.colorScheme, .dark)
            } else {
                HSplitView {
                    if model.showSidebar { SidebarView().frame(minWidth: 185, idealWidth: 215, maxWidth: 280) }
                    browserColumn
                    rightSidebar
                }
                Divider()
                statusBar
            }
        }
        .background(canvasColor)
        .background(SelectionUpdateProbe(assetID: model.focusedID).allowsHitTesting(false))
        .background(KeyboardMonitor(handler: { model.handleKey($0) }, searchOwnership: { model.searchControlsOwnKeyboard = $0 }, searchHasOwnership: { model.searchControlsOwnKeyboard }, keyUpHandler: { event in
            guard model.isNativeEditing, let editing = model.editing else { return false }
            if event.keyCode == 49 {
                let wasPanning = editing.developmentLocalInput.panHeld
                editing.setDevelopmentLocalPanHeld(false)
                return wasPanning
            }
            guard event.charactersIgnoringModifiers?.lowercased() == "m" else { return false }
            editing.setDevelopmentOriginalHeld(false)
            return true
        }, focusChanged: { focused in
            guard model.isNativeEditing, let editing = model.editing else { return }
            if focused {
                if editing.stage == .development { editing.beginDevelopmentInterface() }
            } else {
                editing.setDevelopmentOriginalHeld(false)
                editing.suspendDevelopmentFocus()
            }
        }))
    }
    private var browserColumn: some View {
        Group {
            if model.isCatalog {
                LibraryCatalogView().id(model.catalogKind?.rawValue ?? "catalog")
            } else {
                VStack(spacing: 0) {
                    browserHeader
                    if model.supportsProjectSearch && model.mode == .grid { ProjectSearchHeader().id(model.searchScopeIdentity) }
                    if model.isTriageScope { TriageStatusStrip() }
                    else if model.scope == .session { SessionHistoryBrowsingControls() }
                    Divider()
                    if !model.isPagedGrid && model.scopedAssets.isEmpty && model.mode != .compare { emptyState }
                    else { BrowserView() }
                    Divider()
                    if model.mode == .compare { ComparisonToolbar() }
                    else if model.isTriageScope { TriageDecisionBar() }
                    else if model.isHistoryScope { HistoryActionBar() }
                    else if model.mode == .single { decisionBar }
                    if model.mode != .grid { Divider(); FilmstripView() }
                }
            }
        }.frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
    }
    @ViewBuilder private var rightSidebar: some View {
        if !model.isCatalog && model.mode != .compare && (model.showsRightSidebar || model.isNativeEditing) {
            if model.isNativeEditing, let editing = model.editing {
                NativeEditingInspector(editing: editing).frame(minWidth: 336, idealWidth: 360, maxWidth: 400)
            } else { InspectorView().frame(minWidth: 245, idealWidth: 275, maxWidth: 350) }
        }
    }
    private var toolbarSurface: some View {
        workbenchSurface
        .toolbar {
            ToolbarItem(placement: .navigation) {
                if !model.isNativeEditing {
                    Button { model.showSidebar.toggle() } label: {
                        Label("资料库导航", systemImage: "sidebar.left")
                    }
                    .labelStyle(.iconOnly)
                    .help("显示或收起项目栏")
                    .accessibilityIdentifier("workbench.sidebarToggle")
                }
            }
            ToolbarItem(placement: .principal) {
                WorkflowTabs()
            }
            ToolbarItem(placement: .primaryAction) {
                Button { openWindow(id: "background-activity") } label: {
                    Label("后台信息", systemImage: "waveform.path.ecg").overlay(alignment: .bottom) { WorkbenchFocusUnderline() }
                }
                .labelStyle(.iconOnly).help("后台信息")
                .accessibilityLabel("后台信息").accessibilityIdentifier("workbench.backgroundActivity")
            }
        }
        .navigationTitle("RAWMaster")
        .navigationSubtitle(model.windowContextTitle)
        .toolbarColorScheme(model.isNativeEditing ? .dark : nil, for: .windowToolbar)
        .toolbarBackground(model.isNativeEditing ? AppPalette.panel : Color(nsColor: .windowBackgroundColor), for: .windowToolbar)
        .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
        .toolbarVisibility(.visible, for: .windowToolbar)
        .background(WorkbenchWindowTitleSynchronizer(contextTitle: model.windowContextTitle, darkEditing: model.isNativeEditing))
    }
    private var workflowSheets: some View {
        toolbarSurface
        .modifier(EditingWorkflowPresentation(editing: model.editing))
        .sheet(item: $model.libraryPanel, onDismiss: { model.reload() }) { CatalogWorkspacePanel(panel: $0).environmentObject(model) }
        .sheet(isPresented: $model.showImport) { ImportSheet() }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showTimelapse) {
            if let composer = model.timelapseComposer { TimelapseSheet(composer: composer) }
        }
        .sheet(isPresented: $model.showGroups) { GroupSheet() }
        .sheet(isPresented: $model.showGroupReview) { GroupCommandReviewSheet() }
        .sheet(isPresented: $model.showGroupHistory) { GroupHistoryView() }
        .sheet(isPresented: $model.showExportReport) { ExportReportView() }
        .sheet(isPresented: $model.showRelocation) { RelocationWorkflowView() }
        .sheet(isPresented: $model.showCompletion) { CompletionReviewSheet() }
        .sheet(isPresented: $model.showQualityReview) { QualityEvidenceSheet() }
        .sheet(isPresented: $model.showPairReview) { CapturePairReviewSheet() }
        .sheet(isPresented: $model.showTagPreview) { BatchTagPreviewSheet() }
        .sheet(isPresented: $model.showTagHistory) { TagOperationHistorySheet() }
    }
    private func presentFluxFirstRunIfNeeded() {
        guard !showFluxFirstRun, let services = model.editingServices else { return }
        guard services.fluxModel.shouldShowFirstRunPrompt else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard !showFluxFirstRun, services.fluxModel.shouldShowFirstRunPrompt else { return }
            showFluxFirstRun = true
        }
    }

    var body: some View {
        workflowSheets
        .preferredColorScheme(model.isNativeEditing ? .dark : nil)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard !model.isBusy, let provider = providers.first else { return false }
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                var directory: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue {
                    Task { @MainActor in model.openImport(source: url.path) }
                }
            }; return true
        }
        .onChange(of: model.hasBusinessSheet) { if $0 { model.closeSearchControls() } }
        .onChange(of: model.editingServices != nil, initial: true) { _, available in
            if available { presentFluxFirstRunIfNeeded() }
        }
        .sheet(isPresented: $showFluxFirstRun, onDismiss: { model.editingServices?.fluxModel.markFirstRunPromptShown() }) {
            if let services = model.editingServices {
                FluxFirstRunSheet(
                    model: services.fluxModel,
                    openSettings: { model.openApplicationSettings(.localAI) },
                    dismiss: { showFluxFirstRun = false }
                )
            }
        }
        .onChange(of: model.isNativeEditing, initial: true) { _, editing in
            if editing {
                if sidebarBeforeEditing == nil { sidebarBeforeEditing = model.showSidebar }
                model.showSidebar = false
                if appearanceBeforeEditing == nil { appearanceBeforeEditing = NSApp.appearance }
                NSApp.appearance = NSAppearance(named: .darkAqua)
            } else {
                if let previous = sidebarBeforeEditing {
                    model.showSidebar = previous
                    sidebarBeforeEditing = nil
                }
                NSApp.appearance = appearanceBeforeEditing
                appearanceBeforeEditing = nil
            }
        }
        .onExitCommand {
            if model.canActivateProjectSearch {
                if model.showSearchFilters { model.hideSearchFilters() } else { model.hideSearchField() }
            }
        }
        .onChange(of: model.focusedID) { _, _ in
            model.synchronizeNativeEditingContext()
        }
        .onChange(of: model.focusedAsset?.availability) { _, _ in
            model.synchronizeNativeEditingContext()
        }
        .onChange(of: model.focusedAsset?.resolvedURL) { _, _ in
            model.synchronizeNativeEditingContext()
        }
        .onChange(of: model.mode) {
            model.saveBrowse()
            model.synchronizeNativeEditingContext()
        }
        .onChange(of: model.canOpenNativeEditing) { _, allowed in
            if !allowed { model.editing?.leaveBrowsingContext() }
        }
        .onChange(of: model.filter) { model.saveBrowse() }
        .onChange(of: model.syncCompare) { model.saveBrowse() }
    }
    private var browserHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.canReturnToCatalog || model.mode != .grid {
                HStack(spacing: 10) {
                    if model.mode != .grid {
                        Button { model.setMode(.grid) } label: { Label("照片网格", systemImage: "chevron.left") }
                    } else if model.canReturnToCatalog {
                        Button { model.returnToCatalog() } label: { Label(model.catalogParentTitle, systemImage: "chevron.left") }
                    }
                    if model.canReturnToCatalog && model.mode != .grid {
                        Text(model.catalogParentTitle).foregroundStyle(.tertiary)
                        Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }.font(.caption).buttonStyle(.borderless).padding(.top, model.scope == .session ? 8 : 0)
            }
            if model.scope == .session, let session = model.sessions.first(where: { $0.id == model.scopeID }) {
                SessionWorkflowHeader(session: session)
            } else {
            HStack(spacing: 12) {
                Text(model.scopeTitle).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Spacer(minLength: 8)
                if let group = model.activeGroup { GroupPropertiesButton(groupID: group.id) }
                if model.scope == .group, let group = model.activeGroup, model.isTimelapseGroup(group) {
                    Button { model.openTimelapse() } label: { Label("合成延时视频…", systemImage: "timelapse") }
                        .disabled(!model.canComposeTimelapse()).accessibilityIdentifier("timelapse.open")
                }
                if model.isTriageScope || model.isHistoryScope {
                    Picker("初筛范围", selection: $model.triageFilter) {
                        ForEach(AppModel.TriageFilter.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 118)
                } else if model.scope != .group {
                    Menu {
                        Picker("排序", selection: $model.reviewSort) {
                            ForEach(ProjectReviewSort.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                    } label: { Image(systemName: "arrow.up.arrow.down") }
                        .menuStyle(.borderlessButton).frame(width: 26).help("排序：" + model.reviewSort.title).accessibilityLabel("排序")
                }
                Picker("浏览", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    Image(systemName: "square.grid.2x2").tag(AppModel.BrowserMode.grid)
                    Image(systemName: "rectangle").tag(AppModel.BrowserMode.single)
                    Image(systemName: "rectangle.split.2x1").tag(AppModel.BrowserMode.compare)
                }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("浏览").frame(width: 120).help("网格 G · 单张 E · 比较 C")
            }.frame(height: 26)
            HStack(spacing: 8) {
                Text(headerCounts).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    .help("范围共 \(model.scopeCaptureCount) 次拍摄、\(model.scopeFileCount) 个文件；\(model.keptCount) 个文件入选")
                if model.scope == .project, let progress = model.projectProgress {
                    Text("已审 \(progress.reviewedCaptures)/\(progress.totalCaptures)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary).fixedSize()
                        .help("已审 \(progress.reviewedFiles)/\(progress.totalFiles) 个文件；\(progress.partiallyReviewedCaptures) 个组合部分已审；仅序列用途 \(progress.sequenceOnlyFiles) 个，包含在总数中。")
                }
                Spacer(minLength: 0)
            }.frame(height: 24)
            }
        }.padding(.horizontal, 18).padding(.vertical, model.scope == .session ? 0 : 10)
    }
    private var headerCounts: String {
        if model.isTriageScope { return "\(model.scopeCaptureCount) 次拍摄 · \(model.scopeFileCount) 个文件 · 初筛" }
        if model.isHistoryScope { return "\(model.scopeCaptureCount) 次拍摄 · \(model.scopeFileCount) 个文件 · 导入历史" }
        if model.hasSearchConditions { return "匹配 \(model.matchedCaptureCount)/\(model.scopeCaptureCount) 次 · \(model.matchedFileCount)/\(model.scopeFileCount) 文件" }
        return "\(model.scopeCaptureCount) 次拍摄 · \(model.scopeFileCount) 个文件"
    }
    @ViewBuilder private var emptyState: some View {
        if model.scope == .session {
            VStack(alignment: .leading, spacing: 12) {
                Label("此导入会话尚无照片", systemImage: "tray").font(.title3.weight(.semibold))
                Text(model.isBusy ? "登记的照片会逐步出现在这里，整批任务状态见上方。" : "整批接入与重新分组操作见上方；重新扫描来源与重新分组是两个独立操作。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("返回导入记录") { model.returnToCatalog() }
                Spacer(minLength: 0)
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if model.scope == .group {
            VStack(alignment: .leading, spacing: 12) {
                Label("当前序列没有可浏览的照片", systemImage: "square.stack.3d.up").font(.title3.weight(.semibold))
                Button("返回拍摄序列") { model.returnToCatalog() }
                Spacer(minLength: 0)
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
        VStack(spacing: 18) {
            Image(systemName: "photo.stack").font(.system(size: 48, weight: .ultraLight)).foregroundStyle(AppPalette.accent.opacity(0.75))
            Text(model.isBusy ? "正在发现素材" : "从一次拍摄开始").font(.title2.weight(.medium))
            Text(model.isBusy ? "照片登记后将逐步出现在工作台。" : "接入原片目录，比较细节，留下值得保留的照片。")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            if !model.isBusy {
                Button { model.openImport() } label: { Label("接入素材…", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
                Text("支持原地引用或复制导入，也可以拖入文件夹").font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(40)
        }
    }
    private var decisionBar: some View {
        HStack(spacing: 10) {
            Text(model.actionScopeLabel).font(.caption).foregroundStyle(.secondary).frame(minWidth: 76, alignment: .leading)
            Button { model.decide(.keep) } label: { Label("保留", systemImage: "flag.fill") }.tint(AppPalette.keep).help("P")
            Button { model.decide(.reject) } label: { Label("排除", systemImage: "xmark") }.help("X · 仅改变决定，保留原片和组关系")
            Button { model.decide(.undecided) } label: { Image(systemName: "circle.dotted") }.help("清除决定 U")
            Divider().frame(height: 18)
            RatingButtons(rating: model.focusedAsset?.rating ?? 0) { model.decide(rating: $0) }
            ProjectReviewActions()
            Spacer(minLength: 2)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoCount == 0).help("撤销上一步操作 ⌘Z")
            Menu {
                GroupSelectionActionButton()
                Toggle("决定后自动前进", isOn: $model.autoAdvance)
                Button("刷新文件可用性") { model.refreshAvailability() }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .disabled(model.actionAssetIDs.isEmpty)
        .buttonStyle(.borderless)
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(.regularMaterial)
    }
    private var statusBar: some View {
        VStack(spacing: 0) {
            if let error = model.errorMessage {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(AppPalette.warning)
                    Text(error).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button { model.errorMessage = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }.padding(12).background(AppPalette.warning.opacity(0.12))
            }
            HStack(spacing: 12) {
                if model.scope == .session && (model.sessionTask?.sessionID == model.scopeID || model.sessionTask == nil && !model.isBusy) {
                    Text(model.isHistoryScope ? "历史记录只读 · 恢复仅作用当前所选" : "初筛决定作用当前所选 · 整批会话操作见上方")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                } else if let progress = model.progress {
                    if progress.isRunning { ProgressView().controlSize(.small) }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(progress.title).font(.caption.weight(.semibold))
                            if progress.total > 0 { Text("\(progress.completed) / \(progress.total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            Text(progress.message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if progress.isRunning && progress.total > 0 { ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).frame(maxWidth: 500) }
                    }
                    Spacer()
                    if progress.isRunning {
                        if let task = model.sessionTask {
                            Button(task.isCancelling ? "正在取消…" : "取消任务") { model.cancelSessionTask() }.disabled(task.isCancelling).controlSize(.small)
                        } else { Button("暂停") { model.cancelJob() }.controlSize(.small) }
                    }
                } else {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text(model.isNativeEditing ? "照片编辑 · 原片只读" : (model.isCatalog ? "本地资料库" : "本地资料库 · 决定自动保存 · 原片只读")).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(model.isNativeEditing ? (model.editing?.stage == .development ? "⌘Z 撤销调整 · 按住 M 查看原片" : "候选版本需显式采用") : (model.isCatalog ? "单击选择 · 双击 / Return 打开 · ⌘F 搜索" : "P 保留   X 排除   U 清除   0–5 星级")).font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 16).frame(minHeight: 42).background(panelColor)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 5) {
                Button { model.openImport() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus.circle.fill").font(.system(size: 18))
                        Text("创建导入会话").font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(AppPalette.accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain).foregroundStyle(AppPalette.accent).disabled(model.isBusy)
                    .padding(.bottom, 10).help("创建全局导入会话 · ⌘I")
                sectionTitle("资料库")
                row("全部素材", icon: "photo.on.rectangle.angled", count: model.isPagedGrid ? model.overview?.files ?? 0 : model.publishedAssets.count,
                    selected: model.scope == .all) { model.selectScope(.all) }
                row("导入记录", icon: "tray.and.arrow.down", count: model.isPagedGrid ? model.overview?.sessions ?? 0 : model.sessions.count,
                    selected: model.scope == .imports || model.scope == .session) { model.openImportCatalog() }
                row("拍摄序列", icon: "square.stack.3d.up", count: model.isPagedGrid ? model.overview?.groups ?? 0 : model.visibleGroups.count,
                    selected: model.scope == .sequences || model.scope == .group) { model.openSequenceCatalog() }
                sectionTitle("项目")
                ForEach(model.projects, id: \.id) { project in
                    row(project.name, icon: "folder", count: model.projectFileCount(project.id),
                        selected: model.scope == .project && model.scopeID == project.id) { model.selectScope(.project, id: project.id) }
                }
                if model.projects.isEmpty { Text("尚无项目").font(.caption).foregroundStyle(.secondary).padding(10) }
            }.padding(10)
        }.frame(maxHeight: .infinity)
            .background { if reduceTransparency { AppPalette.panel } else { NativeSidebarMaterial() } }
    }
    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 9).padding(.top, 16).padding(.bottom, 4)
    }
    private func row(_ title: String, icon: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 17).foregroundStyle(selected ? AppPalette.accent : .secondary)
                Text(title).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 8).contentShape(Rectangle())
                .background(selected ? AppPalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var collapsedGroupIDs = Set<String>()
    var body: some View {
        VStack(spacing: 0) {
            if model.mode == .single && !model.isNativeEditing { PairPreviewControls() }
            switch model.mode {
            case .grid: grid.overlay(alignment: .bottom) {
                if model.selectedIDs.count > 1 && !model.isTriageScope && !model.isHistoryScope { GridSelectionActionBar().padding(14) }
            }
            case .single:
                if model.isNativeEditing, let editing = model.editing { EditingImageCanvas(editing: editing) }
                else if let asset = model.focusedAsset { ImagePanel(asset: model.previewAsset(for: asset), actualPixels: model.actualPixels, sharedTransform: nil) }
                else { ContentUnavailableView("选择一张照片", systemImage: "photo") }
            case .compare:
                if model.compareAssets.count >= 2 { ComparisonContentView() }
                else { ComparisonEmptyState() }
            }
            if model.mode == .single && !model.isNativeEditing {
                HStack(spacing: 12) {
                    Button { model.actualPixels.toggle() } label: { Label(model.actualPixels ? "适合窗口" : "查看原始像素 1:1", systemImage: model.actualPixels ? "1.magnifyingglass" : "arrow.down.right.and.arrow.up.left") }.help("Z · 按需解码 RAW 原始分辨率")
                    Spacer()
                    Text("滚轮缩放 · 拖动平移").font(.caption).foregroundStyle(.tertiary)
                }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 9)
            }
        }.background(canvasColor)
    }
    private var grid: some View {
        let layout = model.sequenceBrowserLayout
        let items = layout.gridItems(collapsedGroupIDs: collapsedGroupIDs)
        return GeometryReader { geometry in
            let placement = SequenceGridGeometry(width: geometry.size.width - 36)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(placement.cellWidth), spacing: SequenceGridGeometry.spacing), count: placement.columns),
                              alignment: .leading, spacing: SequenceGridGeometry.spacing) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            SequenceGridCell(item: item, connections: placement.connections(at: index, in: items),
                                header: placement.header(at: index, in: items),
                                headerHeight: placement.headerHeight(inRowContaining: index, items: items),
                                memberships: layout.memberships[item.asset.id] ?? [], collapsedGroupIDs: $collapsedGroupIDs)
                                .environment(\.libraryGridCard, item.asset.id)
                                .overlay { model.paintMark(item.asset.id) }
                                .task(id: model.isPagedGrid && index >= items.count - 6 ? model.assets.count : 0) {
                                    // Several pages of one collapsed sequence can leave the same tail card visible.
                                    if model.isPagedGrid, index >= items.count - 6 { model.catalogGrid?.loadMore() }
                                }
                                .id(item.id)
                        }
                    }.padding(18).padding(.bottom, model.selectedIDs.count > 1 ? 115 : 0)
                    if model.filteredAssets.isEmpty {
                        if model.isPagedGrid && model.catalogGrid?.isLoading == true { ProgressView("读取资料库…").padding(40) }
                        else if let error = model.catalogGrid?.errorDescription, model.isPagedGrid {
                            Text(error).foregroundStyle(.secondary).textSelection(.enabled).padding()
                            Button("重试查询") { model.reload() }
                        } else {
                            ContentUnavailableView("当前筛选下没有素材", systemImage: "line.3.horizontal.decrease.circle")
                                .padding(40).overlay { model.paintMark(nil) }
                        }
                    }
                }.onChange(of: model.navigationReveal) {
                    if let id = model.navigationReveal?.assetID { reveal(id, layout: layout, proxy: proxy) }
                }.onChange(of: model.focusedID) {
                    if let id = model.focusedID, let groupID = layout.primaryGroupID(containing: id) { collapsedGroupIDs.remove(groupID) }
                }.onAppear { if let id = model.focusedID { reveal(id, layout: layout, proxy: proxy) } }
            }
        }
    }
    private func reveal(_ id: String, layout: BrowserSequenceLayout, proxy: ScrollViewProxy) {
        if let groupID = layout.primaryGroupID(containing: id) { collapsedGroupIDs.remove(groupID) }
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }
}

struct GridSelectionActionBar: View {
    @EnvironmentObject var model: AppModel
    @State private var workflow: WorkflowRequest?
    private struct WorkflowRequest: Identifiable {
        let id = UUID()
        let assets: [String]
        let donor: String?
        let results: Bool
    }
    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Text("已选 \(model.selectedIDs.count) 张").font(.caption.weight(.semibold)).foregroundStyle(AppPalette.accent)
                Button { model.decide(.keep) } label: { Label("保留", systemImage: "flag.fill") }.tint(AppPalette.keep)
                Button { model.decide(.reject) } label: { Label("排除", systemImage: "xmark") }
                RatingButtons(rating: model.focusedAsset?.rating ?? 0) { model.decide(rating: $0) }
                ColorLabelPicker(assetIDs: model.actionAssetIDs)
                Spacer(minLength: 0)
                Button { model.selectedIDs = []; model.focusedID = nil } label: { Image(systemName: "xmark.circle.fill") }
                    .help("取消选择").accessibilityLabel("取消选择")
            }.buttonStyle(.borderless)
            Divider()
            HStack(spacing: 8) {
                Button { model.setMode(.compare) } label: { Label("对比", systemImage: "rectangle.split.2x1") }
                Button { model.confirmSelectedPair() } label: { Label("关联 RAW+JPG", systemImage: "link") }
                    .disabled(!model.canLinkSelectedPair).help("选择同一导入会话内的一个 RAW 文件和一个 JPG 文件")
                GroupSelectionActionButton()
                if EditingController.sceneReviewEnabled, model.workbenchExportStore != nil {
                    Menu("更多") {
                        Button("批量工作流…") { openWorkflow(results: false) }.disabled(model.actionAssetIDs.count < 2 || model.actionAssetIDs.count > 201)
                        Button("最近工作流批次与撤销…") { openWorkflow(results: true) }
                    }.accessibilityIdentifier("library.selection.sceneWorkflow")
                }
                Spacer(minLength: 0)
                Button { model.openSelectionExport() } label: { Label("批量导出", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent).disabled(!model.canExport)
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(12).frame(maxWidth: 700)
            .floatingSelectionSurface()
            .accessibilityElement(children: .contain).accessibilityLabel("所选照片操作")
            .sheet(item: $workflow) { request in
                if let store = model.workbenchExportStore {
                    SceneWorkflowBatchSheet(store: store, ids: request.assets, donor: request.donor, showResults: request.results,
                        coordinator: model.sceneWorkflowBatches) { model.prepareLibraryExport(.workflowBatch(versions: $0)) }
                }
            }
    }
    private func openWorkflow(results: Bool) {
        let ids = model.actionAssetIDs
        let focus = model.focusedID.flatMap { ids.contains($0) ? $0 : nil } ?? ids.first
        workflow = .init(assets: ids, donor: focus, results: results || model.sceneWorkflowBatches.running)
    }
}

struct AssetCard: View {
    static let compactHeight: CGFloat = 82

    let asset: AssetRecord
    let selected: Bool
    let compact: Bool
    var previewAsset: AssetRecord? = nil
    var triageDisposition: TriageDisposition? = nil
    var showsCardOutline = true
    var body: some View {
        VStack(spacing: compact ? 3 : 8) {
            ZStack(alignment: .topTrailing) {
                ThumbnailView(asset: previewAsset ?? asset).frame(height: compact ? 62 : 142).frame(maxWidth: .infinity).background(AppPalette.thumbnailWell).clipped()
                if let disposition = triageDisposition {
                    Image(systemName: disposition.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(disposition == .passed ? AppPalette.keep : (disposition == .pending ? .secondary : AppPalette.warning)).padding(6).background(AppPalette.overlay, in: Circle()).padding(5)
                } else if asset.decision != .undecided { Image(systemName: asset.decision.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(asset.decision == .keep ? AppPalette.keep : AppPalette.warning).padding(6).background(AppPalette.overlay, in: Circle()).padding(5) }
            }
            HStack(spacing: 4) {
                Text(asset.filename).lineLimit(1).truncationMode(.middle)
                ColorLabelBadge(assetID: asset.id)
                Spacer(minLength: 1)
                if triageDisposition == nil && asset.rating > 0 {
                    Text(compact ? "★ \(asset.rating)" : String(repeating: "★", count: asset.rating))
                        .foregroundStyle(AppPalette.rating).font(.system(size: 9))
                        .lineLimit(1).fixedSize(horizontal: true, vertical: false)
                }
            }.font(.system(size: compact ? 9 : 11)).foregroundStyle(selected ? .primary : .secondary).padding(.horizontal, compact ? 4 : 8)
            if !compact {
                HStack {
                    Text(asset.camera ?? asset.importState.title).lineLimit(1)
                    Spacer()
                    if asset.error != nil || asset.availability != .available { Image(systemName: "exclamationmark.triangle").foregroundStyle(AppPalette.warning) }
                    if asset.groupID != nil { Image(systemName: "square.stack") }
                }.font(.system(size: 9)).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.bottom, 7)
            }
        }.padding(compact ? 3 : 5)
            .frame(height: compact ? Self.compactHeight : nil)
            .modifier(AssetCardOutline(selected: selected, visible: showsCardOutline))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(triageDisposition.map { "\(asset.filename)，初筛处置：\($0.title)" } ?? "\(asset.filename)，\(asset.decision.title)，\(asset.rating) 星")
    }
}

private struct AssetCardOutline: ViewModifier {
    let selected: Bool
    var visible = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        return content
            .background {
                if visible && selected { shape.fill(AppPalette.accent.opacity(0.12)) }
            }
            .overlay {
                if visible {
                    shape.strokeBorder(selected ? AppPalette.accent : AppPalette.boundary.opacity(0.45), lineWidth: selected ? 2 : 0.5)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: visible ? .black.opacity(selected ? 0.10 : 0.035) : .clear, radius: selected ? 8 : 3, y: 1)
    }
}

struct ThumbnailView: View {
    @Environment(\.libraryGridCard) private var gridCard
    @EnvironmentObject private var model: AppModel
    let asset: AssetRecord
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit()
                    .overlay { if let gridCard { model.paintMark(gridCard, photo: true) } } }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }.task(id: asset.currentPath + asset.importState.rawValue + asset.availability.rawValue) {
            failed = false
            do { let loaded = try await ImageEngines.browsing.preview(for: asset, maxPixel: 600); guard !Task.isCancelled else { return }; image = loaded }
            catch { if !Task.isCancelled { failed = true } }
        }
    }
}

struct ImagePanel: View {
    @EnvironmentObject var model: AppModel
    let asset: AssetRecord
    let actualPixels: Bool
    let sharedTransform: Binding<ImageTransform>?
    var loader: PanelImageLoader = .live
    @State private var image: NSImage?
    @State private var detailReady = false
    @State private var loading = false
    @State private var error: String?
    @State private var localTransform = ImageTransform()
    @State private var detailRequested = false
    @State private var loadedAssetID: String?
    private var needsDetail: Bool { actualPixels || detailRequested }
    private var isRAW: Bool { ["arw", "dng", "raw", "cr2", "cr3", "nef", "raf", "orf", "rw2"].contains(URL(fileURLWithPath: asset.currentPath).pathExtension.lowercased()) }
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ZoomableImageView(image: image, actualPixels: actualPixels, transform: sharedTransform ?? $localTransform, backgroundColor: AppPalette.canvasNSColor, onActualPixelsChange: { model.actualPixels = $0 }, onRequestDetail: { detailRequested = true })
                if image == nil && loading { ProgressView("读取预览…").font(.caption) }
                if let error {
                    VStack(spacing: 8) { Image(systemName: "exclamationmark.triangle").foregroundStyle(AppPalette.warning); Text(error).font(.caption).multilineTextAlignment(.center).textSelection(.enabled) }.padding(20).frame(maxWidth: 340).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 7) {
                Text(asset.filename).font(.caption).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if loading { ProgressView().controlSize(.mini) }
                Text(detailReady ? (isRAW ? "RAW 原始分辨率 · 基础渲染" : "原始分辨率 · 文件图像") : (needsDetail ? "预览 · 正在请求原始细节" : "内嵌 / 文件预览"))
                    .font(.system(size: 9)).foregroundStyle(detailReady ? AppPalette.accent : .secondary).lineLimit(1)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(AppPalette.overlay)
        }.background(AppPalette.thumbnailWell)
        .onChange(of: asset.id) { _, _ in detailRequested = false; localTransform = ImageTransform() }
        .onChange(of: (sharedTransform?.wrappedValue ?? localTransform).scale) { _, scale in
            if scale > 1.05 && !detailRequested { detailRequested = true }
        }
        .onChange(of: actualPixels) { _, actual in
            if !actual {
                let effective = sharedTransform?.wrappedValue ?? localTransform
                if let physical = effective.physicalMagnification, abs(physical - 1) > 0.0001 {
                    // A wheel/pinch gesture left 1:1 and provided an explicit new zoom.
                    // Keep that zoom and the RAW image; Z/button exit from 1:1 resets fit.
                    detailRequested = true
                } else {
                    detailRequested = false
                    localTransform = ImageTransform()
                    sharedTransform?.wrappedValue = ImageTransform()
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if asset.availability != .available {
                Label(asset.availability.title, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(AppPalette.warning).padding(9).background(AppPalette.overlay, in: RoundedRectangle(cornerRadius: 6)).padding(12)
            }
        }
        .task(id: asset.id + asset.currentPath + (needsDetail ? ".detail" : ".preview") + asset.importState.rawValue + asset.availability.rawValue) {
            loading = true; error = nil; detailReady = false
            if loadedAssetID != asset.id { image = nil; loadedAssetID = asset.id }
            do {
                do {
                    let preview = try await loader.preview(asset, 2400)
                    guard !Task.isCancelled else { return }
                    image = preview
                } catch { if !needsDetail { throw error } }
                if needsDetail {
                    let detail = try await loader.detail(asset)
                    guard !Task.isCancelled else { return }
                    image = detail; detailReady = true
                }
            } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
            if !Task.isCancelled { loading = false }
        }
    }
}

struct FilmstripView: View {
    @EnvironmentObject var model: AppModel
    @State private var collapsedGroupIDs = Set<String>()
    var body: some View {
        let layout = model.sequenceBrowserLayout
        let tileHeight = filmstripTileHeight(layout)
        let verticalInset: CGFloat = 5
        let rowHeight = tileHeight + 2 * verticalInset
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(alignment: .center, spacing: 9) {
                    ForEach(layout.segments) { segment in
                        SequenceFilmstripSection(segment: segment, height: rowHeight, collapsedGroupIDs: $collapsedGroupIDs) {
                            let grouped = segment.group != nil
                            LazyHStack(spacing: 8) {
                                ForEach(segment.assets, id: \.id) { asset in
                                    WorkflowAssetTile(asset: asset, compact: true,
                                                      sequenceMemberships: layout.memberships[asset.id] ?? [],
                                                      showsCardOutline: grouped)
                                        .frame(width: 110, height: tileHeight, alignment: .top)
                                        .frame(height: grouped ? tileHeight : rowHeight)
                                        .modifier(AssetCardOutline(selected: model.selectedIDs.contains(asset.id), visible: !grouped))
                                        .id(asset.id)
                                }
                            }
                        }
                    }
                    if layout.segments.isEmpty {
                        Label("当前范围没有照片", systemImage: "photo.on.rectangle").font(.caption).foregroundStyle(.secondary)
                            .frame(height: rowHeight)
                    }
                }.padding(.horizontal, 12).padding(.vertical, 4)
            }.frame(height: rowHeight + 8).background(AppPalette.canvas)
                .onChange(of: model.navigationReveal) { if let id = model.navigationReveal?.assetID { reveal(id, layout: layout, proxy: proxy) } }
                .onChange(of: model.focusedID) {
                    if let id = model.focusedID, let groupID = layout.primaryGroupID(containing: id) { collapsedGroupIDs.remove(groupID) }
                }
                .onAppear { if let id = model.focusedID { reveal(id, layout: layout, proxy: proxy) } }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("browser.filmstrip")
        }
    }
    private func filmstripTileHeight(_ layout: BrowserSequenceLayout) -> CGFloat {
        // Use the entire scope so folding a group cannot move the thumbnail baseline.
        var accessoryRows = 0
        for segment in layout.segments {
            for asset in segment.assets {
                let hasPair = model.pair(for: asset.id) != nil
                let hasMemberships = (layout.memberships[asset.id]?.count ?? 0) > 1
                if hasPair && hasMemberships { return AssetCard.compactHeight + 32 }
                if hasPair || hasMemberships { accessoryRows = 1 }
            }
        }
        return AssetCard.compactHeight + CGFloat(accessoryRows) * 16
    }

    private func reveal(_ id: String, layout: BrowserSequenceLayout, proxy: ScrollViewProxy) {
        if let groupID = layout.primaryGroupID(containing: id) { collapsedGroupIDs.remove(groupID) }
        DispatchQueue.main.async { proxy.scrollTo(id) }
    }
}

struct RatingButtons: View {
    let rating: Int
    let action: (Int) -> Void
    var body: some View {
        HStack(spacing: 3) {
            Button { action(0) } label: { Image(systemName: "minus.circle").font(.system(size: 10)) }.help("清除星级 · 0")
            ForEach(1..<6) { value in Button { action(value) } label: { Image(systemName: rating >= value ? "star.fill" : "star").foregroundStyle(rating >= value ? AppPalette.rating : .secondary).font(.system(size: 11)) }.help("\(value) 星") }
        }.buttonStyle(.plain)
    }
}

struct InspectorView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("照片信息").font(.headline)
                    Spacer()
                    Button { model.inspectWorks() } label: { Image(systemName: "info.circle") }
                        .buttonStyle(.borderless).help("打开完整元数据、直方图与对焦检查")
                        .disabled(model.isTriageScope || model.actionAssetIDs.isEmpty)
                }
                if let asset = model.focusedAsset {
                    Text(asset.filename).font(.system(size: 14, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    if model.isTriageScope || model.isHistoryScope {
                        section("初筛处置") {
                            Label(model.disposition(of: asset.id).title, systemImage: model.disposition(of: asset.id).symbol).font(.caption)
                            Text(model.actionScopeLabel).font(.caption).foregroundStyle(.secondary)
                            if let evidence = model.evidence(for: asset.id) {
                                Text(evidence.status.displayTitle).font(.caption).foregroundStyle(evidence.status == .risk ? AppPalette.warning : .secondary)
                                Text(evidence.reasons.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                    section("选片决定") {
                        HStack { Image(systemName: asset.decision.symbol).foregroundStyle(asset.decision == .keep ? AppPalette.keep : .secondary); Text(asset.decision.title); Spacer() }
                        RatingButtons(rating: asset.rating) { model.decide(rating: $0) }
                        if model.selectedIDs.count > 1 { Text("操作应用到已选 \(model.selectedIDs.count) 张").font(.caption).foregroundStyle(AppPalette.accent) }
                    }
                    section("审阅进度") {
                        Label(model.isReviewed(asset.id) ? "已审" : "未审", systemImage: model.isReviewed(asset.id) ? "checkmark.circle" : "circle")
                            .font(.caption)
                        HStack { Button("标记已审") { model.markSelectedReviewed(true) }; Button("标记未审") { model.markSelectedReviewed(false) } }.controlSize(.small).disabled(model.actionAssetIDs.isEmpty)
                        Text("浏览不标记已审；评分或决定会标记。撤销决定保留已审记录。").font(.caption).foregroundStyle(.secondary)
                    }
                    section("颜色标签") {
                        ColorLabelPicker(assetIDs: model.actionAssetIDs)
                        Text("颜色标签独立保存，可通过搜索筛选；使用“移除颜色标签”清除。").font(.caption).foregroundStyle(.secondary)
                    }
                    section("文字标签") { BatchTagEditor() }
                    }
                    if let pair = model.pair(for: asset.id) {
                        section("RAW + JPEG") {
                            Group {
                                if model.hasSearchConditions {
                                    Text("当前检索仅操作所选的匹配成员，不包含未匹配的伴随文件。")
                                } else if model.pairHasConflict(pair) {
                                    Text("两个文件已有决定不一致，保持原值；操作仅作用于所选成员。")
                                } else {
                                    Text(model.collapses(pair) ? "当前组合卡操作作用于整对；展开后可单独操作。" : "当前逐文件显示，操作仅作用于所选成员。")
                                }
                            }.font(.caption).foregroundStyle(.secondary)
                            Button("展开 / 收起组合") { model.togglePair(pair) }.controlSize(.small)
                            if model.canMaintainPairs { Button("解除关联") { model.unlinkPair(pair.id) }.controlSize(.small) }
                        }
                    }
                    section("拍摄与文件") {
                        info("相机", asset.camera ?? "读取中 / 未知")
                        if let width = asset.width, let height = asset.height { info("分辨率", "\(width) × \(height)") }
                        info("大小", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                        if let date = asset.capturedAt { info("拍摄时间", date.formatted(date: .abbreviated, time: .standard)) }
                        info("接入状态", asset.importState.title)
                        info("可用性", asset.availability.title)
                        if model.isSequenceOnly(asset.id) { Label("仅序列用途 · 默认不进入单张精选交付", systemImage: "square.stack").font(.caption).foregroundStyle(.secondary) }
                        if let error = asset.error { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                    }
                    section("手动拍摄组") {
                        let memberships = model.groups.filter { $0.assetIDs.contains(asset.id) }
                        if memberships.isEmpty { Text("尚未分组").font(.caption).foregroundStyle(.secondary) }
                        ForEach(memberships, id: \.id) { group in
                            if model.isTriageScope {
                                Button { model.editGroup(group.id) } label: { Label("\(group.name) · \(group.kind) · 管理", systemImage: "square.stack.3d.up") }.buttonStyle(.plain).font(.caption).foregroundStyle(AppPalette.accent)
                            } else {
                                Button { model.selectScope(.group, id: group.id); model.select(asset) } label: { Label("\(group.name) · \(group.kind)", systemImage: "square.stack.3d.up") }.buttonStyle(.plain).font(.caption).foregroundStyle(AppPalette.accent)
                            }
                        }
                        GroupSelectionActionButton().controlSize(.small)
                        if let group = model.activeGroup {
                            Button { model.editGroup(group.id) } label: { Label(group.locked ? "组结构受保护 · 管理…" : "组结构未保护 · 管理…", systemImage: group.locked ? "lock" : "lock.open") }.buttonStyle(.plain).font(.caption).foregroundStyle(AppPalette.accent)
                            Text("组内顺序：\((model.activeGroup?.assetIDs.firstIndex(of: asset.id) ?? 0) + 1)").font(.caption)
                            HStack { Button("向前") { model.reorder(-1) }; Button("向后") { model.reorder(1) } }.controlSize(.small)
                            Menu("所选的序列用途") {
                                Button("参与当前序列") { model.setSequence(true) }
                                Button("不参与当前序列") { model.setSequence(false) }
                                Divider()
                                Button("从拍摄组中移除") { model.removeFromGroup() }.disabled(!model.canPerformGroupSelectionAction)
                            }.controlSize(.small)
                        }
                        Text(model.activeGroup.map { $0.includedAssetIDs.contains(asset.id) ? "参与当前序列；排除决定不会移除序列成员。" : "当前不参与此序列。" } ?? (asset.isSequenceMember ? "参与至少一个序列；排除决定不会移除序列成员。" : "独立选片决定与序列参与分别保存。"))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    section("原片位置") {
                        Text(asset.currentPath).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Button("在 Finder 中显示") { model.reveal(asset.currentPath) }.controlSize(.small)
                        if asset.availability != .available {
                            Button("查找原片…") { model.prepareRelocation(sessionID: asset.sessionID, assetIDs: [asset.id], role: model.sessions.first { $0.id == asset.sessionID }?.mode == .copy ? .managed : .source) }.controlSize(.small)
                        }
                        Menu("重新定位位置…") {
                            Button("查找原始来源…") { model.prepareRelocation(sessionID: asset.sessionID, assetIDs: [asset.id], role: .source) }
                            if model.sessions.first(where: { $0.id == asset.sessionID })?.mode == .copy {
                                Button("查找受管副本…") { model.prepareRelocation(sessionID: asset.sessionID, assetIDs: [asset.id], role: .managed) }
                            }
                        }.controlSize(.small).disabled(model.isBusy)
                        if asset.resolvedSourceURL.path != asset.sourcePath { Text("当前来源：\(asset.resolvedSourceURL.path)").font(.system(size: 10)).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        if asset.currentPath != asset.sourcePath { Text("导入时来源：\(asset.sourcePath)").font(.system(size: 10)).foregroundStyle(.tertiary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                    }
                } else { Text("选择照片查看拍摄信息与决定。 ").font(.caption).foregroundStyle(.secondary) }
            }.padding(18)
        }.background(panelColor)
    }
    private func info(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) { Text(key).foregroundStyle(.secondary); Spacer(); Text(value).multilineTextAlignment(.trailing).textSelection(.enabled) }.font(.caption)
    }
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 11) { Divider(); Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary); content() }
    }
}


/// Maintains the context shown by the Window menu and the editor's native chrome.
struct WorkbenchWindowTitleSynchronizer: NSViewRepresentable {
    let contextTitle: String
    var darkEditing = false

    static func apply(to window: NSWindow?, contextTitle: String, darkEditing: Bool = false) {
        guard let window else { return }
        let title = contextTitle.isEmpty ? "RAWMaster" : "RAWMaster – " + contextTitle
        if window.title != title { window.title = title }
        if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
        if !window.isMovable { window.isMovable = true }
        if !window.styleMask.contains(.resizable) { window.styleMask.insert(.resizable) }
        if let zoomButton = window.standardWindowButton(.zoomButton), !zoomButton.isEnabled {
            zoomButton.isEnabled = true
        }
        let minimumSize = CGSize(width: 1100, height: 720)
        if window.minSize != minimumSize { window.minSize = minimumSize }
        let appearance = darkEditing ? NSAppearance(named: .darkAqua) : nil
        if window.appearance?.name != appearance?.name { window.appearance = appearance }
        // The unified toolbar may retain its light background on entry to the editor.
        if window.titlebarAppearsTransparent != darkEditing {
            window.titlebarAppearsTransparent = darkEditing
        }
        let backgroundColor = darkEditing ? AppPalette.panelNSColor : NSColor.windowBackgroundColor
        if window.backgroundColor != backgroundColor { window.backgroundColor = backgroundColor }
    }

    final class AnchorView: NSView {
        var contextTitle = ""
        var darkEditing = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
            if let window {
                NotificationCenter.default.addObserver(self, selector: #selector(windowBecameKey(_:)),
                    name: NSWindow.didBecomeKeyNotification, object: window)
            }
            apply()
        }

        @objc private func windowBecameKey(_ notification: Notification) { apply() }

        func apply() {
            WorkbenchWindowTitleSynchronizer.apply(to: window, contextTitle: contextTitle, darkEditing: darkEditing)
        }
    }

    func makeNSView(context: Context) -> AnchorView { AnchorView(frame: .zero) }

    func updateNSView(_ view: AnchorView, context: Context) {
        view.contextTitle = contextTitle
        view.darkEditing = darkEditing
        view.apply()
    }
}
