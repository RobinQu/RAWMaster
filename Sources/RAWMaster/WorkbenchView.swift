import AppKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore
import RAWMasterImaging

private let canvasColor = AppPalette.canvas
private let panelColor = AppPalette.panel

struct WorkbenchView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HSplitView {
                if model.showSidebar { SidebarView().frame(minWidth: 185, idealWidth: 215, maxWidth: 280) }
                VStack(spacing: 0) {
                    browserHeader
                    Divider()
                    if model.scopedAssets.isEmpty { emptyState }
                    else { BrowserView() }
                    Divider()
                    decisionBar
                    if !model.filteredAssets.isEmpty { Divider(); FilmstripView() }
                }.frame(minWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
                if model.showInspector { InspectorView().frame(minWidth: 245, idealWidth: 275, maxWidth: 350) }
            }
            Divider()
            statusBar
        }
        .background(canvasColor)
        .background(SelectionUpdateProbe(assetID: model.focusedID).allowsHitTesting(false))
        .background(KeyboardMonitor { model.handleKey($0) })
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button { model.showSidebar.toggle() } label: { Image(systemName: "sidebar.left") }.help("显示或收起项目栏")
            }
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    BrandIconView(size: 24)
                    Text("RAWMaster").font(.headline)
                    Text("LOCAL CULLING").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
                }
                // Decorative toolbar content must let title-bar double clicks and drags
                // reach AppKit, just like the surrounding empty title-bar area.
                .allowsHitTesting(false)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.openImport() } label: { Label("接入素材", systemImage: "square.and.arrow.down") }.disabled(model.isBusy)
                Button { model.showExport = true } label: { Label("交付精选", systemImage: "square.and.arrow.up") }.disabled(model.scopedAssets.isEmpty || model.isBusy)
                Button { model.showInspector.toggle() } label: { Image(systemName: "sidebar.right") }.help("信息栏 · Tab")
            }
        }
        .sheet(isPresented: $model.showImport) { ImportSheet() }
        .sheet(isPresented: $model.showExport) { ExportSheet() }
        .sheet(isPresented: $model.showGroups) { GroupSheet() }
        .sheet(isPresented: $model.showGroupReview) { GroupCommandReviewSheet() }
        .sheet(isPresented: $model.showGroupHistory) { GroupHistoryView() }
        .sheet(isPresented: $model.showExportReport) { ExportReportView() }
        .sheet(isPresented: $model.showRelocation) { RelocationWorkflowView() }
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
        .onChange(of: model.mode) { model.saveBrowse() }
        .onChange(of: model.filter) { model.saveBrowse() }
    }
    private var browserHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.scopeTitle).font(.system(size: 20, weight: .semibold)).lineLimit(1)
                Text("\(model.scopedAssets.count) 张已登记 · \(model.keptCount) 张保留 · \(model.scope == .group ? "组内顺序" : "按文件名")").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            Picker("筛选", selection: $model.filter) {
                ForEach(AppModel.Filter.allCases, id: \.self) { Text($0.title).tag($0) }
            }.labelsHidden().frame(width: 112)
            Picker("浏览", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                Image(systemName: "square.grid.2x2").tag(AppModel.BrowserMode.grid)
                Image(systemName: "rectangle").tag(AppModel.BrowserMode.single)
                Image(systemName: "rectangle.split.2x1").tag(AppModel.BrowserMode.compare)
            }.pickerStyle(.segmented).labelsHidden().accessibilityLabel("浏览").frame(width: 120).help("网格 G · 单张 E · 比较 C")
        }.padding(.horizontal, 20).padding(.vertical, 15)
    }
    private var emptyState: some View {
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
    private var decisionBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(model.selectedIDs.count) 张").font(.caption).foregroundStyle(.secondary).frame(minWidth: 76, alignment: .leading)
            Button { model.decide(.keep) } label: { Label("保留", systemImage: "flag.fill") }.tint(AppPalette.keep).help("P")
            Button { model.decide(.reject) } label: { Label("排除", systemImage: "xmark") }.help("X · 仅改变决定，保留原片和组关系")
            Button { model.decide(.undecided) } label: { Image(systemName: "circle.dotted") }.help("清除决定 U")
            Divider().frame(height: 18)
            RatingButtons(rating: model.focusedAsset?.rating ?? 0) { model.decide(rating: $0) }
            Spacer(minLength: 2)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(model.undoCount == 0).help("撤销上一步操作 ⌘Z")
            Menu {
                Button("建立拍摄组…") { model.editGroup() }
                Toggle("决定后自动前进", isOn: $model.autoAdvance)
                Button("刷新文件可用性") { model.refreshAvailability() }
            } label: { Image(systemName: "ellipsis.circle") }.menuStyle(.borderlessButton).frame(width: 24)
        }
        .disabled(model.selectedIDs.isEmpty)
        .buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 11).background(panelColor)
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
                if let progress = model.progress {
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
                    if progress.isRunning { Button("暂停") { model.cancelJob() }.controlSize(.small) }
                } else {
                    Image(systemName: "externaldrive").foregroundStyle(.secondary)
                    Text("本地资料库 · 决定自动保存 · 原片只读").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("P 保留   X 排除   U 清除   0–5 星级").font(.caption).foregroundStyle(.tertiary)
                }
            }.padding(.horizontal, 16).frame(minHeight: 42).background(panelColor)
        }
    }
}

struct SidebarView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 7) {
                sectionTitle("资料库")
                row("全部素材", icon: "photo.on.rectangle.angled", count: model.assets.count, selected: model.scope == .all) { model.selectScope(.all) }
                sectionTitle("项目")
                ForEach(model.projects, id: \.id) { project in
                    row(project.name, icon: "folder", count: model.assets.filter { $0.projectID == project.id }.count, selected: model.scope == .project && model.scopeID == project.id) { model.selectScope(.project, id: project.id) }
                }
                if model.projects.isEmpty { Text("尚无项目").font(.caption).foregroundStyle(.tertiary).padding(.horizontal, 10) }
                sectionTitle("导入会话")
                ForEach(model.sessions, id: \.id) { session in
                    VStack(alignment: .leading, spacing: 2) {
                        row(URL(fileURLWithPath: session.sourcePath).lastPathComponent, icon: session.mode == .copy ? "doc.on.doc" : "link", count: session.discovered, selected: model.scope == .session && model.scopeID == session.id) { model.selectScope(.session, id: session.id) }
                        HStack(spacing: 4) {
                            Text(model.statusTitle(for: session)).lineLimit(1)
                            if session.failed > 0 { Text("· \(session.failed) 异常").foregroundStyle(AppPalette.warning) }
                        }.font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 36)
                    }.contextMenu {
                        Button("继续 / 重新校验") { model.resume(session) }.disabled(model.isBusy)
                        Divider()
                        Button("重新定位原始来源…") { model.prepareRelocation(sessionID: session.id, role: .source) }.disabled(model.isBusy)
                        if session.mode == .copy { Button("重新定位受管副本…") { model.prepareRelocation(sessionID: session.id, role: .managed) }.disabled(model.isBusy) }
                        Button("在 Finder 中显示当前来源") { model.reveal(session.effectiveSourceURL.path) }
                    }
                }
                if !model.relocationHistory.isEmpty {
                    sectionTitle("找回原片记录")
                    ForEach(model.relocationHistory, id: \.id) { report in
                        Button { model.reviewRelocation(report) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Label("\(report.role.title) · \(report.items.count) 张", systemImage: "externaldrive.badge.magnifyingglass")
                                Text(report.statusTitle).font(.system(size: 10)).foregroundStyle(.secondary)
                            }.font(.caption).padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain).disabled(model.relocationIsRunning && model.relocationReport?.id != report.id)
                    }
                }
                sectionTitle("手动拍摄组")
                ForEach(model.groups, id: \.id) { group in
                    row(group.name, icon: group.locked ? "lock" : "square.stack.3d.up", count: group.assetIDs.count, selected: model.scope == .group && model.scopeID == group.id) { model.selectScope(.group, id: group.id) }
                        .contextMenu { Button("管理拍摄组…") { model.editGroup(group.id) } }
                }
                Button { model.editGroup() } label: { Label("将所选建立为组", systemImage: "plus") }.buttonStyle(.plain).font(.caption).padding(9).foregroundStyle(.secondary).disabled(model.selectedIDs.isEmpty)
                Button { model.openGroupHistory() } label: { Label("最近组操作…", systemImage: "clock.arrow.circlepath") }.buttonStyle(.plain).font(.caption).padding(9).foregroundStyle(.secondary)
                Spacer(minLength: 20)
                Text("排除不会删除原片，也不会移出序列。")
                    .font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true).padding(10)
            }.padding(10)
        }.background(panelColor)
    }
    private func sectionTitle(_ title: String) -> some View { Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 9).padding(.top, 18).padding(.bottom, 4) }
    private func row(_ title: String, icon: String, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: icon).frame(width: 17).foregroundStyle(selected ? AppPalette.accent : .secondary)
                Text(title).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(count)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }.font(.system(size: 12)).padding(.horizontal, 9).padding(.vertical, 8).contentShape(Rectangle())
                .background(selected ? AppPalette.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
        }.buttonStyle(.plain)
    }
}

struct BrowserView: View {
    @EnvironmentObject var model: AppModel
    @State private var compareTransform = ImageTransform()
    var body: some View {
        VStack(spacing: 0) {
            switch model.mode {
            case .grid: grid
            case .single:
                if let asset = model.focusedAsset { ImagePanel(asset: asset, actualPixels: model.actualPixels, sharedTransform: nil) }
                else { ContentUnavailableView("选择一张照片", systemImage: "photo") }
            case .compare:
                if model.compareAssets.count >= 2 { comparison }
                else { ContentUnavailableView("选择 2–4 张照片进行比较", systemImage: "rectangle.split.2x1", description: Text("在网格或胶片条按住 ⌘ 点击多选，然后按 C。")) }
            }
            if model.mode != .grid {
                HStack(spacing: 12) {
                    Button { model.actualPixels.toggle() } label: { Label(model.actualPixels ? "适合窗口" : "查看原始像素 1:1", systemImage: model.actualPixels ? "1.magnifyingglass" : "arrow.down.right.and.arrow.up.left") }.help("Z · 按需解码 RAW 原始分辨率")
                    if model.mode == .compare { Toggle("同步缩放与平移", isOn: $model.syncCompare).toggleStyle(.checkbox) }
                    Spacer()
                    Text("滚轮缩放 · 拖动平移").font(.caption).foregroundStyle(.tertiary)
                }.font(.caption).buttonStyle(.borderless).padding(.horizontal, 16).padding(.vertical, 9)
            }
        }.background(canvasColor)
    }
    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 290), spacing: 14)], spacing: 14) {
                    ForEach(model.filteredAssets, id: \.id) { asset in
                        AssetCard(asset: asset, selected: model.selectedIDs.contains(asset.id), compact: false)
                            .id(asset.id)
                            .overlay(CardInputLayer(onPress: { model.select(asset, modifiers: $0) }, onDoubleClick: { model.select(asset); model.setMode(.single) }))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.select(asset) }
                            .contextMenu { assetMenu(asset) }
                    }
                }.padding(18)
                if model.filteredAssets.isEmpty { ContentUnavailableView("当前筛选下没有素材", systemImage: "line.3.horizontal.decrease.circle").padding(40) }
            }.onChange(of: model.navigationReveal) { if let request = model.navigationReveal { proxy.scrollTo(request.assetID) } }
                .onAppear { if let id = model.focusedID { proxy.scrollTo(id) } }
        }
    }
    private var comparison: some View {
        GeometryReader { geometry in
            let columns = model.compareAssets.count == 2 ? 2 : 2
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: columns), spacing: 1) {
                ForEach(model.compareAssets, id: \.id) { asset in
                    ImagePanel(asset: asset, actualPixels: model.actualPixels, sharedTransform: model.syncCompare ? $compareTransform : nil)
                        .frame(height: max(100, (geometry.size.height - 1) / CGFloat(model.compareAssets.count > 2 ? 2 : 1)))
                        .overlay(alignment: .topLeading) {
                            Button { model.focusedID = asset.id } label: { Image(systemName: asset.id == model.focusedID ? "circle.inset.filled" : "circle").padding(9) }.buttonStyle(.plain).foregroundStyle(AppPalette.accent)
                        }
                }
            }
        }
    }
    @ViewBuilder private func assetMenu(_ asset: AssetRecord) -> some View {
        Button("单张查看") { model.select(asset); model.setMode(.single) }
        Button("保留") { model.select(asset); model.decide(.keep) }
        Button("排除") { model.select(asset); model.decide(.reject) }
        Divider()
        Button("在 Finder 中显示") { model.reveal(asset.currentPath) }
    }
}

struct AssetCard: View {
    let asset: AssetRecord
    let selected: Bool
    let compact: Bool
    var body: some View {
        VStack(spacing: compact ? 3 : 8) {
            ZStack(alignment: .topTrailing) {
                ThumbnailView(asset: asset).frame(height: compact ? 62 : 142).frame(maxWidth: .infinity).background(AppPalette.thumbnailWell).clipped()
                if asset.decision != .undecided { Image(systemName: asset.decision.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(asset.decision == .keep ? AppPalette.keep : AppPalette.warning).padding(6).background(AppPalette.overlay, in: Circle()).padding(5) }
            }
            HStack(spacing: 4) {
                Text(asset.filename).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 1)
                if asset.rating > 0 { Text(String(repeating: "★", count: asset.rating)).foregroundStyle(AppPalette.rating).font(.system(size: 9)) }
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
            .background(selected ? AppPalette.accent.opacity(0.10) : panelColor, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? AppPalette.accent : AppPalette.boundary, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(asset.filename)，\(asset.decision.title)，\(asset.rating) 星")
    }
}

struct ThumbnailView: View {
    let asset: AssetRecord
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        ZStack {
            if let image { Image(nsImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            else { ProgressView().controlSize(.small) }
        }.task(id: asset.currentPath + asset.importState.rawValue + asset.availability.rawValue) {
            failed = false
            do { let loaded = try await ImagePipeline.shared.preview(for: asset, maxPixel: 600); guard !Task.isCancelled else { return }; image = loaded }
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
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 8) {
                    ForEach(model.filteredAssets, id: \.id) { asset in
                        AssetCard(asset: asset, selected: model.selectedIDs.contains(asset.id), compact: true).frame(width: 102).id(asset.id)
                            .overlay(CardInputLayer(onPress: { model.select(asset, modifiers: $0) }, onDoubleClick: { model.select(asset); model.setMode(.single) }))
                            .accessibilityAddTraits(.isButton)
                            .accessibilityAction { model.select(asset) }
                    }
                }.padding(.horizontal, 14).padding(.vertical, 10)
            }.frame(height: 105).background(AppPalette.canvas)
                .onChange(of: model.navigationReveal) { if let request = model.navigationReveal { proxy.scrollTo(request.assetID) } }
                .onAppear { if let id = model.focusedID { proxy.scrollTo(id) } }
        }
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
                HStack { Text("照片信息").font(.headline); Spacer(); Image(systemName: "info.circle").foregroundStyle(.secondary) }
                if let asset = model.focusedAsset {
                    Text(asset.filename).font(.system(size: 14, weight: .medium)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    section("选片决定") {
                        HStack { Image(systemName: asset.decision.symbol).foregroundStyle(asset.decision == .keep ? AppPalette.keep : .secondary); Text(asset.decision.title); Spacer() }
                        RatingButtons(rating: asset.rating) { model.decide(rating: $0) }
                        if model.selectedIDs.count > 1 { Text("操作应用到已选 \(model.selectedIDs.count) 张").font(.caption).foregroundStyle(AppPalette.accent) }
                    }
                    section("拍摄与文件") {
                        info("相机", asset.camera ?? "读取中 / 未知")
                        if let width = asset.width, let height = asset.height { info("分辨率", "\(width) × \(height)") }
                        info("大小", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                        if let date = asset.capturedAt { info("拍摄时间", date.formatted(date: .abbreviated, time: .standard)) }
                        info("接入状态", asset.importState.title)
                        info("可用性", asset.availability.title)
                        if let error = asset.error { Text(error).font(.caption).foregroundStyle(AppPalette.warning).textSelection(.enabled) }
                    }
                    section("手动拍摄组") {
                        let memberships = model.groups.filter { $0.assetIDs.contains(asset.id) }
                        if memberships.isEmpty { Text("尚未分组").font(.caption).foregroundStyle(.secondary) }
                        ForEach(memberships, id: \.id) { group in
                            Button { model.selectScope(.group, id: group.id); model.select(asset) } label: { Label("\(group.name) · \(group.kind)", systemImage: "square.stack.3d.up") }.buttonStyle(.plain).font(.caption).foregroundStyle(AppPalette.accent)
                        }
                        Button("将所选建立为组…") { model.editGroup() }.controlSize(.small)
                        if let group = model.activeGroup {
                            Button { model.editGroup(group.id) } label: { Label(group.locked ? "组结构受保护 · 管理…" : "组结构未保护 · 管理…", systemImage: group.locked ? "lock" : "lock.open") }.buttonStyle(.plain).font(.caption).foregroundStyle(AppPalette.accent)
                            Text("组内顺序：\((model.activeGroup?.assetIDs.firstIndex(of: asset.id) ?? 0) + 1)").font(.caption)
                            HStack { Button("向前") { model.reorder(-1) }; Button("向后") { model.reorder(1) } }.controlSize(.small)
                            Menu("所选的序列用途") {
                                Button("参与当前序列") { model.setSequence(true) }
                                Button("不参与当前序列") { model.setSequence(false) }
                                Divider()
                                Button("从当前组移出") { model.removeFromGroup() }
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
