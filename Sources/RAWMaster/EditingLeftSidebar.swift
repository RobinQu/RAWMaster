import SwiftUI
import RAWMasterCore

/// Filters, named snapshots and linear history share one vertical tool stack.
struct EditingLeftSidebar: View {
    @ObservedObject var editing: EditingController
    let presetCatalog: DevelopmentPresetCatalog
    @State private var summaryExpanded = true
    @State private var filtersExpanded = true
    @State private var snapshotsExpanded = true
    @State private var historyExpanded = false
    @State private var lensName: String?
    @State private var renamingSnapshot: DevelopmentSnapshot?
    @State private var snapshotName = ""
    @FocusState private var resultsMenuFocused: Bool
    @FocusState private var focusedSnapshot: DevelopmentSnapshot.ID?

    init(editing: EditingController, presetCatalog: DevelopmentPresetCatalog = .shared) {
        self.editing = editing
        self.presetCatalog = presetCatalog
    }

    var body: some View {
        VStack(spacing: EditingLayout.panelSpacing) {
            LeftRailSection(title: "RAW 摘要", symbol: "doc.text.magnifyingglass", expanded: $summaryExpanded) {
                rawSummary
            }
            .frame(maxWidth: .infinity)
            .floatingSelectionSurface()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("editing.rail.summary")
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .floatingSelectionSurface()
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("editing.rail.tools")
        }
        .frame(width: EditingLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("滤镜、快照与操作历史")
        .accessibilityIdentifier("editing.leftRail")
        .sheet(isPresented: Binding(get: { editing.savedResultsSelection != nil }, set: { if !$0 { editing.closeSavedResults() } }),
               onDismiss: { if !editing.quickPromptPresented { resultsMenuFocused = true } }) {
            EditingSavedResultsSheet(editing: editing)
        }
        .alert("重命名快照", isPresented: Binding(get: { renamingSnapshot != nil }, set: { if !$0 { renamingSnapshot = nil } })) {
            TextField("快照名称", text: $snapshotName)
            Button("取消") { renamingSnapshot = nil }
            Button("存储") { renameSnapshot() }.disabled(snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private var content: some View {
        if let context = editing.developmentPresentationContext, let work = editing.work {
            let session = editing.developmentSession
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        DevelopmentPresetBrowser(editing: editing, session: session, context: context, assetID: work.source.assetID, scroller: proxy,
                            catalog: presetCatalog, sectionExpanded: $filtersExpanded)
                        Divider().opacity(0.65)
                        LeftRailSection(title: "快照", symbol: "camera.viewfinder", expanded: $snapshotsExpanded,
                                        accessory: resultsMenu, actionSymbol: "plus", actionLabel: "创建快照", actionIdentifier: "editing.snapshots.create") {
                            createSnapshot(context: context)
                        } content: {
                            snapshotList(session: session, context: context)
                        }
                        Divider().opacity(0.65)
                        LeftRailSection(title: "历史", symbol: "clock.arrow.circlepath", expanded: $historyExpanded) {
                            history(session: session, context: context)
                        }
                    }
                }
                .coordinateSpace(name: "photos.inspector.scroll")
                .onAppear { if historyExpanded { scrollToCurrent(session: session, proxy: proxy) } }
                .onChange(of: historyExpanded) { _, expanded in
                    if expanded { scrollToCurrent(session: session, proxy: proxy) }
                }
                .onChange(of: session.historyItems.map(\.id)) { _, _ in
                    if historyExpanded { scrollToCurrent(session: session, proxy: proxy) }
                }
            }
            .disabled(editing.developmentContext == nil)
        } else if editing.visibleSceneGraph != nil, let work = editing.work {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ScenePresetDirectory(catalog: presetCatalog, sectionExpanded: $filtersExpanded,
                                         favoriteLooks: editing.favoriteDevelopmentFilters) { error in
                        editing.postNotice("无法读取滤镜目录。\(error.localizedDescription)", kind: .error, for: work.source.assetID)
                    }
                    Divider()
                    let ticket = editing.sceneTicket
                    LeftRailSection(title: "快照", symbol: "camera.viewfinder", expanded: $snapshotsExpanded, accessory: resultsMenu,
                                    actionSymbol: "plus", actionLabel: "创建快照", actionIdentifier: "editing.snapshots.create",
                                    action: ticket.map { ticket in { editing.createSceneSnapshot(ticket: ticket) } }) {
                        if editing.sceneSnapshots.isEmpty {
                            Text("尚无快照").photosInspectorParagraph().foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.bottom, 12)
                        } else if let ticket {
                            ForEach(editing.sceneSnapshots) { snapshot in
                                HStack(spacing: 2) {
                                    Button { editing.restoreSceneSnapshot(snapshot.id, ticket: ticket) } label: {
                                        EditingSidebarRowLabel(title: snapshot.name, symbol: "photo", active: snapshot.recipe == editing.recipe) { _ in }
                                    }
                                    .buttonStyle(.plain).accessibilityIdentifier("editing.snapshot." + snapshot.id.uuidString)
                                    Menu {
                                        Button("重命名…") { snapshotName = snapshot.name; renamingSnapshot = snapshot }
                                        Button("删除", role: .destructive) { editing.updateSceneSnapshot(snapshot.id, name: nil, ticket: ticket) }
                                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 24) }
                                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("快照操作")
                                }.padding(.horizontal, 12)
                            }
                        }
                    }
                    Divider()
                    LeftRailSection(title: "历史", symbol: "clock.arrow.circlepath", expanded: $historyExpanded) {
                        HStack {
                            Button { editing.stepSceneHistory(redo: false) } label: { Label("撤销", systemImage: "arrow.uturn.backward") }
                                .disabled(!editing.sceneCanUndo).accessibilityIdentifier("editing.history.undo")
                            Button { editing.stepSceneHistory(redo: true) } label: { Label("重做", systemImage: "arrow.uturn.forward") }
                                .disabled(!editing.sceneCanRedo).accessibilityIdentifier("editing.history.redo")
                        }.font(.caption).padding(.bottom, 10)
                    }
                }
            }
        } else {
            VStack(alignment: .leading, spacing: PhotosControlLayout.descriptionSpacing) {
                LeftRailSection(title: "快照", symbol: "camera.viewfinder", expanded: $snapshotsExpanded, accessory: resultsMenu) {
                    Text("原片可用后可以继续调整和创建快照。")
                        .photosInspectorParagraph().foregroundStyle(.secondary).padding(.horizontal, 14)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var resultsMenu: AnyView {
        AnyView(Menu {
            Button("已有编辑结果…") { editing.showSavedResults() }
        } label: {
            Image(systemName: "ellipsis").frame(width: 24, height: 26)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .disabled(editing.work == nil || editing.loading)
        .focused($resultsMenuFocused)
        .help("更多快照操作").accessibilityLabel("更多快照操作").accessibilityIdentifier("editing.snapshots.more"))
    }

    @ViewBuilder private var rawSummary: some View {
        if let asset = editing.asset {
            VStack(alignment: .leading, spacing: 7) {
                Text(asset.filename).font(.system(size: 11, weight: .semibold))
                    .lineLimit(2).truncationMode(.middle).textSelection(.enabled)
                summaryRow("大小", ByteCountFormatter.string(fromByteCount: asset.fileSize, countStyle: .file))
                summaryRow("分辨率", asset.width.flatMap { width in asset.height.map { "\(width) × \($0)" } } ?? "—")
                summaryRow("相机", asset.camera ?? "—")
                summaryRow("镜头", lensName ?? "读取中…")
            }
            .padding(.horizontal, 14).padding(.bottom, 13)
            .accessibilityIdentifier("editing.rawSummary")
            .task(id: asset.id + asset.resolvedURL.path) {
                lensName = nil
                let snapshot = await Task.detached(priority: .utility) {
                    ComparisonSnapshot.read(asset: asset, histogram: false)
                }.value
                guard !Task.isCancelled else { return }
                lensName = snapshot.values["镜头"] ?? "—"
            }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
                .lineLimit(2).truncationMode(.middle)
        }
        .font(.system(size: 10))
    }

    @ViewBuilder private func snapshotList(session: EditingDevelopmentSession,
                                           context: EditingInteractionContext) -> some View {
        let snapshots = session.snapshots(in: context)
        if snapshots.isEmpty {
            Text("尚无快照").photosInspectorParagraph().foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 12)
        } else {
            LazyVStack(spacing: 2) {
                ForEach(snapshots) { snapshot in
                    snapshotRow(snapshot, session: session, context: context)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 10)
            .onChange(of: focusedSnapshot) { previous, next in
                if let previous { editing.cancelPresetHover(id: "snapshot." + previous.uuidString) }
                if let next { editing.previewDevelopmentSnapshot(id: next, context: context) }
            }
        }
    }

    private func snapshotRow(_ snapshot: DevelopmentSnapshot, session: EditingDevelopmentSession,
                             context: EditingInteractionContext) -> some View {
        let hoverID = "snapshot." + snapshot.id.uuidString
        let restore = { restoreSnapshot(snapshot, session: session, context: context) }
        return HStack(spacing: 4) {
            Button(action: restore) {
                EditingSidebarRowLabel(title: snapshot.name, symbol: "photo") { inside in
                    if inside { editing.previewDevelopmentSnapshot(id: snapshot.id, context: context) }
                    else { editing.cancelPresetHover(id: hoverID) }
                }
            }
            .buttonStyle(.plain)
            .focused($focusedSnapshot, equals: snapshot.id)
            .onKeyPress(.return) { restore(); return .handled }
            .onKeyPress(.escape) {
                editing.cancelPresetHover(id: hoverID)
                focusedSnapshot = nil
                return .handled
            }
            .onDisappear { editing.cancelPresetHover(id: hoverID) }
            .help("悬停试看，点击恢复快照")
            .accessibilityIdentifier("editing.snapshot." + snapshot.id.uuidString)

            Menu {
                Button("重命名…") { snapshotName = snapshot.name; renamingSnapshot = snapshot }
                Divider()
                Button("删除", role: .destructive) { deleteSnapshot(snapshot, session: session, context: context) }
            } label: {
                Image(systemName: "ellipsis").frame(width: 24, height: 24)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("快照操作")
        }
    }

    private func history(session: EditingDevelopmentSession, context: EditingInteractionContext) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button { editing.undoDevelopment(context: context) } label: {
                    Label("撤销", systemImage: "arrow.uturn.backward").font(.caption).frame(height: 26)
                }
                .buttonStyle(.plain).disabled(!session.canUndo)
                .help(session.undoTitle.map { "撤销 \($0) · ⌘Z" } ?? "撤销 · ⌘Z")
                .accessibilityLabel("撤销调整").accessibilityIdentifier("editing.history.undo")
                Button { editing.undoDevelopment(context: context, redo: true) } label: {
                    Label("重做", systemImage: "arrow.uturn.forward").font(.caption).frame(height: 26)
                }
                .buttonStyle(.plain).disabled(!session.canRedo)
                .help(session.redoTitle.map { "重做 \($0) · ⇧⌘Z" } ?? "重做 · ⇧⌘Z")
                .accessibilityLabel("重做调整").accessibilityIdentifier("editing.history.redo")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.bottom, 8)
            if session.historyItems.isEmpty {
                Text("尚无调整记录。完成的调整会记录在这里。")
                    .photosInspectorParagraph().foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                LazyVStack(spacing: 2) {
                    ForEach(session.historyItems) { item in
                        Button { restore(item, session: session, context: context) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: item.isCurrent ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 10))
                                    .foregroundColor(item.isCurrent ? AppPalette.accent : Color.secondary)
                                Text(item.title).font(.system(size: 11))
                                    .foregroundColor(item.isFuture ? Color.secondary : Color.primary)
                                    .lineLimit(2).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 7)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(item.isCurrent ? AppPalette.accent.opacity(0.12) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("editing.history.item.\(item.position)")
                        .accessibilityAddTraits(item.isCurrent ? .isSelected : [])
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 7).padding(.bottom, 10)
            }
        }
        .padding(.bottom, 2)
        .accessibilityIdentifier("editing.leftRail.history")
    }

    private func createSnapshot(context: EditingInteractionContext) {
        do { _ = try editing.developmentSession.createSnapshot(context: context) }
        catch { editing.message = "无法创建快照，请完成当前调整后重试。" }
    }
    private func renameSnapshot() {
        guard let snapshot = renamingSnapshot else { return }
        if snapshot.recipe.sceneGraph != nil, let ticket = editing.sceneTicket {
            editing.updateSceneSnapshot(snapshot.id, name: snapshotName, ticket: ticket)
            renamingSnapshot = nil
            return
        }
        guard let context = editing.developmentContext else { renamingSnapshot = nil; return }
        do { try editing.developmentSession.renameSnapshot(id: snapshot.id, name: snapshotName, context: context) }
        catch { editing.message = "无法重命名快照，请重试。" }
        renamingSnapshot = nil
    }
    private func deleteSnapshot(_ snapshot: DevelopmentSnapshot, session: EditingDevelopmentSession,
                                context: EditingInteractionContext) {
        do { try session.deleteSnapshot(id: snapshot.id, context: context) }
        catch { editing.message = "无法删除快照，请重试。" }
    }
    private func restoreSnapshot(_ snapshot: DevelopmentSnapshot, session: EditingDevelopmentSession,
                                 context: EditingInteractionContext) {
        editing.cancelPresetHover()
        do { try session.restoreSnapshot(id: snapshot.id, context: context) }
        catch { editing.message = "无法恢复快照，请检查当前照片。" }
    }
    private func restore(_ item: DevelopmentHistoryItem, session: EditingDevelopmentSession,
                         context: EditingInteractionContext) {
        do {
            try session.restoreHistory(position: item.position, context: context,
                input: .capture(control: "photos.history.restore", phase: "discrete", nativeEvent: true))
        } catch { editing.message = "无法恢复这条历史状态，请检查当前照片。" }
    }
    private func scrollToCurrent(session: EditingDevelopmentSession, proxy: ScrollViewProxy) {
        guard let current = session.historyItems.first(where: { $0.isCurrent }) else { return }
        DispatchQueue.main.async { proxy.scrollTo(current.id, anchor: .center) }
    }
}

struct LeftRailSection<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var expanded: Bool
    var headingIdentifier = ""
    var enabled: Binding<Bool>? = nil
    var enableDisabled = false
    var resetAction: (() -> Void)? = nil
    var resetDisabled = false
    var accessory: AnyView? = nil
    @Environment(\.colorScheme) private var colorScheme
    @State private var hovering = false
    var actionSymbol: String? = nil
    var actionLabel = ""
    var actionIdentifier = ""
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Button { withAnimation(.easeOut(duration: 0.16)) { expanded.toggle() } } label: {
                    HStack(spacing: 6) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold)).frame(width: 11).foregroundStyle(.secondary)
                        Image(systemName: symbol).font(.system(size: 13)).frame(width: 16).foregroundStyle(.secondary)
                        Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title)，\(expanded ? "收起" : "展开")")
                .accessibilityIdentifier(headingIdentifier)
                if let resetAction {
                    Button(action: resetAction) {
                        Image(systemName: "arrow.uturn.backward").font(.system(size: 12))
                            .foregroundStyle(resetDisabled ? .tertiary : .secondary)
                            .frame(width: 26, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(resetDisabled).help("复位滤镜").accessibilityLabel("复位滤镜")
                    .accessibilityIdentifier("editing.filters.reset")
                }
                if let enabled {
                    Button { enabled.wrappedValue.toggle() } label: {
                        Image(systemName: enabled.wrappedValue ? "circle.inset.filled" : "circle")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(enabled.wrappedValue ? Color.accentColor : Color.secondary)
                            .frame(width: 27, height: 28).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).disabled(enableDisabled)
                    .help("启用或停用\(title)，保留已设置的数值")
                    .accessibilityAddTraits(.isToggle).accessibilityLabel("启用" + title)
                    .accessibilityValue(enabled.wrappedValue ? "已启用" : "已停用")
                    .accessibilityIdentifier("editing.filters.enabled")
                }
                if let action, let actionSymbol {
                    Button(action: action) { Image(systemName: actionSymbol).font(.system(size: 12)).frame(width: 26, height: 28) }
                        .buttonStyle(.plain).help(actionLabel).accessibilityLabel(actionLabel)
                        .accessibilityIdentifier(actionIdentifier)
                }
                if let accessory { accessory }
            }
            .frame(minHeight: 32)
            .foregroundStyle(photosAdjustmentTextColor(in: colorScheme))
            .background(hovering ? Color.primary.opacity(0.04) : Color.clear, in: RoundedRectangle(cornerRadius: 5))
            .onHover { hovering = $0 }
            .padding(.horizontal, 12).padding(.vertical, 2)
            if expanded { content().padding(.top, PhotosControlLayout.spacing).transition(.opacity) }
        }
    }
}


/// The title occupies the available row width. Secondary actions keep their own hit targets.
struct EditingSidebarRowLabel: View {
    let title: String
    let symbol: String
    var active = false
    var onHover: (Bool) -> Void
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).foregroundStyle(.secondary)
                .frame(width: 13)
            Text(title).lineLimit(1)
            Spacer(minLength: 0)
            if active { Image(systemName: "checkmark").font(.system(size: 9)) }
        }
        .font(.system(size: 11))
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, minHeight: 25, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 5)
                .fill(active ? AppPalette.accent.opacity(0.13) : Color.primary.opacity(hovered ? 0.06 : 0))
        }
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside; onHover(inside) }
    }
}
