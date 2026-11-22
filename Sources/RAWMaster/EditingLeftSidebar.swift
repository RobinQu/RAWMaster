import SwiftUI
import RAWMasterCore

/// Filters, named snapshots and linear history share one vertical tool stack.
struct EditingLeftSidebar: View {
    @ObservedObject var editing: EditingController
    var presetCatalog: DevelopmentPresetCatalog = .shared
    @State private var summaryExpanded = true
    @State private var filtersExpanded = true
    @State private var snapshotsExpanded = true
    @State private var historyExpanded = false
    @State private var lensName: String?
    @State private var renamingSnapshot: DevelopmentSnapshot?
    @State private var snapshotName = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("照片工具").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 14).padding(.top, 14).padding(.bottom, 10)
            Divider()
            content
        }
        .frame(width: EditingLayout.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background(Color.clear)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("滤镜、快照与操作历史")
        .accessibilityIdentifier("editing.leftRail")
        .alert("重命名快照", isPresented: Binding(get: { renamingSnapshot != nil }, set: { if !$0 { renamingSnapshot = nil } })) {
            TextField("快照名称", text: $snapshotName)
            Button("取消") { renamingSnapshot = nil }
            Button("存储") { renameSnapshot() }.disabled(snapshotName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private var content: some View {
        if let context = editing.developmentPresentationContext {
            let session = editing.developmentSession
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        LeftRailSection(title: "RAW 摘要", symbol: "doc.text.magnifyingglass", expanded: $summaryExpanded) {
                            rawSummary
                        }
                        Divider().opacity(0.65)
                        LeftRailSection(title: "预设", symbol: "camera.filters", expanded: $filtersExpanded, headingIdentifier: "editing.leftRail.filters") {
                            DevelopmentPresetBrowser(editing: editing, session: session, context: context, scroller: proxy, catalog: presetCatalog)
                                .padding(.horizontal, 12).padding(.bottom, 12)
                        }
                        Divider().opacity(0.65)
                        LeftRailSection(title: "快照", symbol: "camera.viewfinder", expanded: $snapshotsExpanded,
                                        actionSymbol: "plus", actionLabel: "创建快照", actionIdentifier: "editing.snapshots.create") {
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
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Label("保留当前工具状态", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Text("照片恢复后会继续显示滤镜、快照和操作历史。")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(16).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
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
        if session.snapshots.isEmpty {
            Text("点击 + 保存当前调整状态；之后可随时恢复，且不会覆盖历史。")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14).padding(.bottom, 12)
        } else {
            LazyVStack(spacing: 3) {
                ForEach(session.snapshots) { snapshot in
                    HStack(spacing: 6) {
                        Button {
                            restoreSnapshot(snapshot, session: session, context: context)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: snapshot.recipe == session.recipe ? "checkmark.circle.fill" : "camera.viewfinder")
                                    .font(.system(size: 11))
                                    .foregroundStyle(snapshot.recipe == session.recipe ? AppPalette.accent : Color.secondary)
                                Text(snapshot.name).font(.system(size: 11)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: 30)
                            .background(snapshot.recipe == session.recipe ? AppPalette.accent.opacity(0.11) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("恢复此快照；恢复操作可通过撤销退回")
                        .accessibilityIdentifier("editing.snapshot.\(snapshot.id.uuidString)")
                        Menu {
                            Button("重命名…") { snapshotName = snapshot.name; renamingSnapshot = snapshot }
                            Divider()
                            Button("删除", role: .destructive) { deleteSnapshot(snapshot, session: session, context: context) }
                        } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                            .menuStyle(.borderlessButton)
                            .accessibilityLabel("快照操作")
                    }
                    .padding(.horizontal, 6)
                }
            }
            .padding(.horizontal, 6).padding(.bottom, 10)
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
                    .font(.caption2).foregroundStyle(.tertiary)
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
        guard let snapshot = renamingSnapshot, let context = editing.developmentContext else { renamingSnapshot = nil; return }
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

private struct LeftRailSection<Content: View>: View {
    let title: String
    let symbol: String
    @Binding var expanded: Bool
    var headingIdentifier = ""
    var enabled: Binding<Bool>? = nil
    var enableDisabled = false
    var resetAction: (() -> Void)? = nil
    var actionSymbol: String? = nil
    var actionLabel = ""
    var actionIdentifier = ""
    var action: (() -> Void)? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 7) {
                Button { withAnimation(.easeOut(duration: 0.18)) { expanded.toggle() } } label: {
                    HStack(spacing: 7) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Image(systemName: symbol).font(.system(size: 11)).frame(width: 16)
                        Text(title).font(.system(size: 12, weight: .semibold))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title)，\(expanded ? "收起" : "展开")")
                .accessibilityIdentifier(headingIdentifier)
                if let resetAction {
                    Button(action: resetAction) { Image(systemName: "arrow.uturn.backward").frame(width: 24, height: 26) }
                        .buttonStyle(.plain).help("复位滤镜").accessibilityLabel("复位滤镜")
                        .accessibilityIdentifier("editing.filters.reset")
                }
                if let enabled {
                    Toggle("启用" + title, isOn: enabled).labelsHidden().toggleStyle(.checkbox)
                        .disabled(enableDisabled).accessibilityIdentifier("editing.filters.enabled")
                }
                if let action, let actionSymbol {
                    Button(action: action) { Image(systemName: actionSymbol).frame(width: 26, height: 26) }
                        .buttonStyle(.plain).help(actionLabel).accessibilityLabel(actionLabel)
                        .accessibilityIdentifier(actionIdentifier)
                }
            }
            .padding(.horizontal, 10)
            if expanded { content().transition(.opacity) }
        }
    }
}
