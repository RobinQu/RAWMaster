import SwiftUI
import RAWMasterCore
import RAWMasterImaging

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}

struct PhotosThumbnailVisibility: ViewModifier {
    let editing: EditingController
    let context: EditingInteractionContext
    let kind: DevelopmentThumbnailKind
    let viewportHeight: CGFloat
    @State private var lastRect: CGRect = .zero
    private func evaluate(_ rect: CGRect, height: CGFloat, reason: ThumbnailDiagnosticReason) {
        let finite = [rect.minX, rect.minY, rect.width, rect.height, height].allSatisfy(\.isFinite)
        let visible = finite && rect.width > 0 && rect.height > 0 && height > 0 && rect.maxY > 0 && rect.minY < height
        InteractionTrace.shared.thumbnail(.visibility, kind: kind) {
            .init(reason: reason, flags: [.finite: finite, .scopeMatch: editing.developmentContext == context, .computedVisible: visible],
                numbers: [.x: Double(rect.minX), .y: Double(rect.minY), .width: Double(rect.width),
                          .height: Double(rect.height), .viewportHeight: Double(height)])
        }
        editing.developmentThumbnails.setVisible(kind, visible, context: context)
    }
    func body(content: Content) -> some View {
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named("photos.inspector.scroll"))
        } action: { rect in
            lastRect = rect; evaluate(rect, height: viewportHeight, reason: .rect)
        }.onChange(of: viewportHeight) { _, height in evaluate(lastRect, height: height, reason: .height) }
            .onChange(of: context) { _, _ in evaluate(lastRect, height: viewportHeight, reason: .context) }
            .onAppear { evaluate(lastRect, height: viewportHeight, reason: .appear) }
            .onDisappear {
                InteractionTrace.shared.thumbnail(.visibility, kind: kind) {
                    .init(reason: .disappear, flags: [.scopeMatch: editing.developmentContext == context, .computedVisible: false])
                }
                editing.developmentThumbnails.setVisible(kind, false, context: context)
            }
    }
}

/// The mounted image surface keeps its own input sequence even when its edit detaches the images.
struct PhotosThumbnailTracking {
    private(set) var active = false
    mutating func begin(hasImages: Bool) -> Bool {
        guard !active, hasImages else { return false }
        active = true; return true
    }
    mutating func end() -> Bool {
        guard active else { return false }
        active = false; return true
    }
}
struct PhotosThumbnailStrip: View {
    @ObservedObject var owner: EditingThumbnailPresentation
    let kind: DevelopmentThumbnailKind
    let value: Double
    let context: EditingInteractionContext
    let interaction: (Bool) -> Void
    let change: (Double) -> Void
    @State private var tracking = PhotosThumbnailTracking()
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // This surface remains mounted through an image gesture's own invalidation.
                // Idle/status has a separate hit/AX subtree and cannot begin a summary edit.
                Group {
                    if let set = owner.sets[kind.presentationKey] {
                        HStack(spacing: 1) {
                            ForEach(Array(set.images.enumerated()), id: \.offset) { _, image in
                                Image(nsImage: image).resizable().scaledToFill().frame(width: max(1, (geometry.size.width - 4) / 5), height: 48).clipped()
                            }
                        }
                    } else { Color.clear }
                }.frame(width: geometry.size.width, height: 48).contentShape(Rectangle())
                    .allowsHitTesting(owner.sets[kind.presentationKey] != nil || tracking.active)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { event in
                        guard tracking.active || owner.sets[kind.presentationKey] != nil else { return }
                        if tracking.begin(hasImages: owner.sets[kind.presentationKey] != nil) { interaction(true) }
                        if geometry.size.width > 0 { change(min(1, max(-1, event.location.x / geometry.size.width * 2 - 1))) }
                    }.onEnded { _ in if tracking.end() { interaction(false) } })
                    .accessibilityElement(children: .ignore).accessibilityLabel("效果强度")
                    .accessibilityValue(DevelopmentNumericText.format(value, fractionDigits: 2))
                    .accessibilityHidden(owner.sets[kind.presentationKey] == nil)
                    .accessibilityAdjustableAction { direction in
                        guard owner.sets[kind.presentationKey] != nil else { return }
                        interaction(true)
                        change(min(1, max(-1, value + (direction == .increment ? 0.1 : -0.1))))
                        interaction(false)
                    }
                if owner.sets[kind.presentationKey] == nil && !tracking.active {
                    PhotosThumbnailStatus(owner: owner, kind: kind, context: context)
                }
            }.frame(width: geometry.size.width, height: 48)
        }.frame(height: 48).clipShape(RoundedRectangle(cornerRadius: 4))
            .help("效果条为缩略图示意，请以主图为准。")
            .onDisappear { if tracking.end() { interaction(false) } }
    }
}
struct PhotosThumbnailStatus: View {
    @ObservedObject var owner: EditingThumbnailPresentation
    let kind: DevelopmentThumbnailKind
    let context: EditingInteractionContext
    var body: some View {
        HStack {
            if owner.state(kind).isBusy {
                TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                    HStack { ProgressView().controlSize(.mini); Text(owner.progressText(kind)).font(.caption) }
                }
            } else if owner.state(kind) != .ready {
                Text(owner.errors[kind.presentationKey] ?? (owner.state(kind) == .waitingForSource
                    ? "等待当前照片预览完成。" : "效果预览尚未开始。"))
                    .font(.caption).foregroundStyle(.secondary)
                Button("重试预览") { owner.retry(kind, context: context) }.font(.caption)
                    .accessibilityIdentifier("photos.\(kind.presentationKey).thumbnail.retry")
            }
        }.frame(minHeight: 48)
    }
}

extension DevelopmentPhotoFilterV3 {
    var photosName: String {
        switch self {
        case .original: return "原片"
        case .vivid: return "鲜明"
        case .vividWarm: return "鲜明暖色"
        case .vividCool: return "鲜明冷色"
        case .dramatic: return "反差色"
        case .dramaticWarm: return "反差暖色"
        case .dramaticCool: return "反差冷色"
        case .mono: return "单色"
        case .silvertone: return "银色调"
        case .noir: return "黑白"
        }
    }
}
struct PhotosFilterControls: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var session: EditingDevelopmentSession
    @ObservedObject var owner: EditingThumbnailPresentation
    let context: EditingInteractionContext
    let viewportHeight: CGFloat
    @FocusState private var focusedFilter: DevelopmentPhotoFilterV3?
    private var filter: DevelopmentFilterV3 { session.parameters.filter }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("预览基于当前照片生成，仅在区块可见时渲染。")
                .font(.caption2).foregroundStyle(.secondary)
            if owner.isRefreshing(.filters), owner.sets[DevelopmentThumbnailKind.filters.presentationKey] != nil {
                HStack(spacing: 5) { ProgressView().controlSize(.mini); Text("正在更新滤镜预览…") }
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityLabel("正在更新滤镜预览")
            }
            if owner.sets[DevelopmentThumbnailKind.filters.presentationKey] == nil {
                PhotosThumbnailStatus(owner: owner, kind: .filters, context: context)
            } else if let error = owner.errors[DevelopmentThumbnailKind.filters.presentationKey] {
                HStack(spacing: 6) {
                    Text(error).font(.caption2).foregroundStyle(.secondary)
                    Button("重试预览") { owner.retry(.filters, context: context) }.font(.caption2)
                        .accessibilityIdentifier("photos.filters.thumbnail.retry")
                }
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2), spacing: 9) {
                ForEach(editing.displayDevelopmentFilters, id: \.self) { look in
                    let imageIndex = editing.availableDevelopmentFilters.firstIndex(of: look) ?? 0
                    Button {
                        do { try editing.changeDevelopmentFilter(look, context: context) }
                        catch { editing.message = "滤镜未应用，请重试。" }
                    } label: {
                        VStack(spacing: 0) {
                            ZStack {
                                if let image = owner.sets[DevelopmentThumbnailKind.filters.presentationKey]?.images[safe: imageIndex] {
                                    Image(nsImage: image).resizable().scaledToFill()
                                } else {
                                    AppPalette.thumbnailWell
                                    if owner.state(.filters).isBusy { ProgressView().controlSize(.mini) }
                                    else { Image(systemName: "photo").foregroundStyle(.tertiary) }
                                }
                            }
                            .frame(maxWidth: .infinity).frame(height: 68).clipped()
                            HStack(spacing: 4) {
                                if selected(look) { Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)) }
                                Text(look.photosName).font(.system(size: 10, weight: selected(look) ? .semibold : .regular)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 7).frame(maxWidth: .infinity, minHeight: 25)
                        }
                        .background(selected(look) ? AppPalette.accent.opacity(0.14) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                        .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected(look) ? AppPalette.accent.opacity(0.8) : AppPalette.boundary.opacity(0.28), lineWidth: selected(look) ? 1.2 : 0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                        .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(look.photosName)
                    .accessibilityIdentifier("editing.filter.\(look.rawValue)")
                    .accessibilityAddTraits(selected(look) ? .isSelected : [])
                    .overlay(alignment: .topTrailing) {
                        if look != .original {
                            Button {
                                editing.toggleDevelopmentFilterFavorite(look)
                            } label: {
                                Image(systemName: editing.favoriteDevelopmentFilters.contains(look) ? "star.fill" : "star")
                                    .font(.system(size: 10)).padding(6)
                            }.buttonStyle(.plain)
                                .accessibilityLabel(editing.favoriteDevelopmentFilters.contains(look) ? "取消收藏\(look.photosName)" : "收藏\(look.photosName)")
                                .accessibilityIdentifier("editing.filter.favorite.\(look.rawValue)")
                        }
                    }
                    .onHover { hovering in
                        if hovering { editing.previewDevelopmentFilter(look, context: context) }
                        else if editing.hoveredDevelopmentFilter == look { editing.cancelDevelopmentFilterHover() }
                    }
                    .focused($focusedFilter, equals: look)
                    .onKeyPress(.leftArrow) { moveFocus(from: look, by: -1) }
                    .onKeyPress(.rightArrow) { moveFocus(from: look, by: 1) }
                    .onKeyPress(.upArrow) { moveFocus(from: look, by: -2) }
                    .onKeyPress(.downArrow) { moveFocus(from: look, by: 2) }
                    .onExitCommand { editing.cancelDevelopmentFilterHover() }
                }
            }
            .modifier(PhotosThumbnailVisibility(editing: editing, context: context, kind: .filters, viewportHeight: viewportHeight))
            .onChange(of: focusedFilter) { _, look in
                if let look, !selected(look) { editing.previewDevelopmentFilter(look, context: context) }
                else if editing.hoveredDevelopmentFilter != nil { editing.cancelDevelopmentFilterHover() }
            }
            .onDisappear { editing.cancelDevelopmentFilterHover() }
            PhotosRecipeValueRow(session: session, context: context, title: "强度", control: "filter.intensity", value: filter.intensity,
                range: 0...100, step: 1, digits: 0, apply: { amount, token in
                    var value = session.parameters.filter; value.intensity = amount
                    if value.selection != .original { value.enabled = true }
                    try session.apply(.setParameters(.filter(value)), event: .init(context: context, control: .init(group: .filter, name: "滤镜强度")), gesture: token)
                }, onError: { _ in editing.message = "滤镜强度未应用，请检查数值。" })
                .disabled(editing.availableDevelopmentFilters.count <= 1 || filter.selection == .original)
        }
    }
    private func moveFocus(from look: DevelopmentPhotoFilterV3, by offset: Int) -> KeyPress.Result {
        let items = editing.displayDevelopmentFilters
        guard let index = items.firstIndex(of: look), items.indices.contains(index + offset) else { return .ignored }
        focusedFilter = items[index + offset]
        return .handled
    }
    private func selected(_ look: DevelopmentPhotoFilterV3) -> Bool { look == .original ? !filter.enabled || filter.selection == .original : filter.enabled && filter.selection == look }
    private func apply(_ command: DevelopmentAdjustmentCommand) {
        do { try session.apply(command, event: .init(context: context, control: .init(group: .filter, name: "滤镜"))) }
        catch { editing.message = "滤镜未应用，请完成当前调整后重试。" }
    }
}
