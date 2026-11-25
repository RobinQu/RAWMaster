import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct EditingCanvasCommand: Equatable {
    enum Action { case fit, zoomIn, zoomOut, center }
    let id = UUID()
    let action: Action
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

struct EditingImageCanvas: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.displayScale) private var backingScale
    @ObservedObject var editing: EditingController
    @ObservedObject var localInput: EditingLocalInputSession
    @ObservedObject var maskInput: EditingMaskInputSession
    @State private var transform = ImageTransform()
    @State private var navigationPreviewOffset: Int?
    @State private var beforeAfterSplit = 0.5
    @State private var canvasWidth: CGFloat = 1100
    @State private var quickPromptShowCandidate = true
    @State private var quickPromptReviewTransform = ImageTransform()
    @State private var quickPromptDetail: QuickPromptDetail?
    @State private var quickPromptDetailLoading = false
    private struct QuickPromptDetail {
        let jobID: String
        let before, after: CGImage
    }
    private struct PickerPresentationSnapshot {
        let context: EditingInteractionContext
        let transform: ImageTransform
        let actualPixels: Bool
    }
    @State private var pickerPresentationSnapshot: PickerPresentationSnapshot?
    init(editing: EditingController) {
        self.editing = editing; self.localInput = editing.developmentLocalInput; self.maskInput = editing.developmentMaskInput
    }
    private var dockWidth: CGFloat {
        min(672, max(280, canvasWidth - 2 * (EditingLayout.sidebarWidth + 2 * EditingLayout.outerPadding) - 24))
    }

    private var quickPromptFitInsets: NSEdgeInsets {
        var insets = EditingLayout.fitInsets
        if editing.quickPromptSelecting {
            insets.bottom = QuickPromptDockLayout.inputHeight(width: dockWidth) + QuickPromptDockLayout.bottomPadding + 10
        }
        return insets
    }

    var body: some View {
        currentPane
        .background(editing.darkroomBackground.color)
        .onGeometryChange(for: CGFloat.self) { geometry in geometry.size.width } action: { canvasWidth = $0 }
        .overlay(alignment: .bottom) {
            QuickPromptDock(editing: editing, width: dockWidth, canvasControls: { canvasControls },
                showCandidate: $quickPromptShowCandidate, inspectPixels: inspectQuickPromptEdge)
                .overlay(alignment: .top) {
                    if !editing.quickPromptPresented { navigationPreview.offset(y: -48) }
                }
                .padding(.bottom, QuickPromptDockLayout.bottomPadding)
        }
        .onChange(of: editing.quickPromptReview?.job.id) { _, _ in
            quickPromptDetail = nil; quickPromptReviewTransform = .init()
        }
        .onChange(of: editing.selectedVersionID) { _, _ in fit() }
        .onChange(of: editing.previews.primary.frame?.id) { _, _ in editing.colorReadout.refresh(editing.previews.primary.frame) }
        .onDisappear { editing.colorReadout.clear() }
        .onChange(of: editing.comparison) { old, new in
            editing.colorReadout.clear()
            if new.isActive && !old.isActive { beforeAfterSplit = 0.5 }
        }
        .onChange(of: editing.developmentContext) { _, context in
            fit()
            if pickerPresentationSnapshot?.context != context { pickerPresentationSnapshot = nil }
        }
        .onChange(of: editing.canvasCommand) { _, command in
            guard let command else { return }
            switch command.action {
            case .fit: fit()
            case .zoomIn: zoom(by: 1.25)
            case .zoomOut: zoom(by: 0.8)
            case .center: center()
            }
        }
        .onChange(of: model.focusedID) { _, _ in navigationPreviewOffset = nil }
        .onChange(of: editing.developmentPicker?.id) { _, pickerID in
            editing.colorReadout.clear()
            if pickerID != nil, pickerPresentationSnapshot == nil, let context = editing.developmentContext {
                pickerPresentationSnapshot = .init(context: context, transform: transform, actualPixels: editing.actualPixels)
            } else if pickerID == nil, let saved = pickerPresentationSnapshot {
                pickerPresentationSnapshot = nil
                guard editing.developmentContext == saved.context else { return }
                transform = saved.transform
                if editing.actualPixels != saved.actualPixels { editing.setActualPixels(saved.actualPixels) }
            }
        }
    }

    private var canvasControls: some View {
        HStack(spacing: 6) {
            navigationButton(offset: -1, symbol: "chevron.left", title: "上一张")
            navigationButton(offset: 1, symbol: "chevron.right", title: "下一张")
            Divider().frame(height: 18)
            Button { editing.requestCanvasCommand(.zoomOut) } label: { Image(systemName: "minus.magnifyingglass").frame(width: 26, height: 26) }
                .help("缩小 · −").accessibilityLabel("缩小").accessibilityIdentifier("editing.zoomOut")
            Button { editing.requestCanvasCommand(.zoomIn) } label: { Image(systemName: "plus.magnifyingglass").frame(width: 26, height: 26) }
                .help("放大 · +").accessibilityLabel("放大").accessibilityIdentifier("editing.zoomIn")
            Button { editing.requestCanvasCommand(.fit) } label: { Text("FIT").font(.system(size: 10, weight: .semibold)).frame(width: 30, height: 26) }
                .help("适合可用画面 · 0 / ⌘0").accessibilityLabel("适合可用画面").accessibilityIdentifier("editing.fit")
            Button {
                if let context = editing.developmentContext { editing.toggleDevelopmentCrop(context: context) }
            } label: {
                Image(systemName: "crop").frame(width: 28, height: 26)
                    .background(editing.cropEditing ? AppPalette.accent.opacity(0.18) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
            }
            .foregroundStyle(editing.cropEditing ? AppPalette.accent : .primary)
            .disabled(editing.stage != .development || editing.developmentContext == nil)
            .help("裁切与拉直 · C").accessibilityLabel("裁切与拉直")
            .accessibilityIdentifier("editing.crop")
            .accessibilityAddTraits(editing.cropEditing ? .isSelected : [])
            Divider().frame(height: 18)
            Menu {
                comparisonModeButton(.off)
                comparisonModeButton(.referenceOnly)
                Section("擦除") {
                    comparisonModeButton(.wipeHorizontal); comparisonModeButton(.wipeVertical)
                }
                Section("合成") {
                    comparisonModeButton(.mix); comparisonModeButton(.difference); comparisonModeButton(.checkerboard)
                }
                Section("并排") {
                    comparisonModeButton(.sideLeftRight); comparisonModeButton(.sideTopBottom)
                }
                Divider()
                Button { editing.setComparisonInverted(!editing.comparison.inverted) } label: {
                    Label("交换参考与当前", systemImage: "arrow.left.arrow.right")
                }
                .disabled(!editing.comparisonMode.supportsInversion)
                .accessibilityIdentifier("editing.beforeAfter.invert")
                Menu("对比对象") {
                    comparisonReferenceButton(.original, title: "原片（当前几何）")
                    if editing.versions.contains(where: { $0.id != editing.work?.originalVersionID }) {
                        Section("当前照片的版本") {
                            ForEach(editing.versions.filter { $0.id != editing.work?.originalVersionID }) { version in
                                comparisonReferenceButton(.version(version.id), title: version.editingTitle)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("editing.beforeAfter.reference")
            } label: {
                Image(systemName: editing.comparing ? editing.comparisonMode.symbol : "rectangle.lefthalf.inset.filled")
                    .frame(width: 28, height: 26)
                    .background(editing.comparing ? AppPalette.accent.opacity(0.16) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 6))
            }
            .menuStyle(.borderlessButton)
            .foregroundStyle(editing.comparing ? AppPalette.accent : .primary)
            .disabled(editing.cropEditing)
            .help("对比模式 · V 开关；可在此选择参考版本")
            .accessibilityLabel("对比模式")
            .accessibilityIdentifier("editing.beforeAfter")
            .accessibilityAddTraits(editing.comparing ? .isSelected : [])
            Menu {
                ForEach(DarkroomBackground.allCases) { background in
                    Button { editing.darkroomBackground = background } label: {
                        HStack(spacing: 10) {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(background.color)
                                .frame(width: 34, height: 20)
                                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.primary.opacity(0.28), lineWidth: 0.6))
                            Text(background.title)
                            Spacer()
                            if background == editing.darkroomBackground { Image(systemName: "checkmark") }
                        }
                    }
                    .accessibilityLabel("背景" + background.title)
                    .accessibilityIdentifier("editing.background." + background.rawValue)
                }
            } label: {
                Image(systemName: "circle.inset.filled").foregroundStyle(editing.darkroomBackground.color)
                    .frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton)
            .help("暗房背景颜色 · B 循环")
            .accessibilityLabel("暗房背景颜色")
            .accessibilityIdentifier("editing.darkroom.background")
        }
    }

    private func comparisonModeButton(_ mode: EditingComparisonMode) -> some View {
        Button { editing.setComparisonMode(mode) } label: {
            Label(mode.title, systemImage: editing.comparisonMode == mode ? "checkmark" : mode.symbol)
        }
        .disabled(mode != .off && editing.cropEditing)
        .accessibilityIdentifier("editing.beforeAfter.mode." + mode.rawValue)
    }

    private func comparisonReferenceButton(_ reference: EditingComparisonReference, title: String) -> some View {
        Button { editing.setComparisonReference(reference) } label: {
            HStack {
                Text(title)
                if editing.comparison.reference == reference { Image(systemName: "checkmark") }
            }
        }
    }

    @ViewBuilder private var navigationPreview: some View {
        if let offset = navigationPreviewOffset, let asset = navigationAsset(offset) {
            VStack(spacing: 5) {
                ThumbnailView(asset: asset).frame(width: 152, height: 96).background(AppPalette.thumbnailWell).clipped()
                Text(asset.filename).font(.caption2).lineLimit(1).truncationMode(.middle).frame(maxWidth: 152)
            }
            .padding(7).floatingSelectionSurface()
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
            .accessibilityLabel((offset < 0 ? "上一张：" : "下一张：") + asset.filename)
            .accessibilityIdentifier(offset < 0 ? "editing.previousPreview" : "editing.nextPreview")
        }
    }

    private func navigationButton(offset: Int, symbol: String, title: String) -> some View {
        Button {
            navigationPreviewOffset = nil
            model.move(offset)
        } label: { Image(systemName: symbol).frame(width: 25, height: 26) }
            .disabled(navigationAsset(offset) == nil)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.16)) { navigationPreviewOffset = hovering ? offset : nil }
            }
            .help(title + (offset < 0 ? " · ←" : " · →"))
            .accessibilityLabel(title)
            .accessibilityIdentifier(offset < 0 ? "editing.previousPhoto" : "editing.nextPhoto")
    }

    private func navigationAsset(_ offset: Int) -> AssetRecord? {
        let items = model.browserAssets
        guard let current = model.focusedID, let index = items.firstIndex(where: { $0.id == current }) else { return items.first }
        let next = index + offset
        return items.indices.contains(next) ? items[next] : nil
    }

    private func fit() {
        transform = ImageTransform()
        if editing.actualPixels { editing.setActualPixels(false, nativeEvent: true) }
    }
    private func center() {
        transform.centerX = 0.5; transform.centerY = 0.5
    }
    private func zoom(by factor: CGFloat) {
        guard !editing.cropEditing, editing.developmentPicker == nil else { return }
        if transform.physicalMagnification != nil {
            transform.physicalMagnification = max(0.025, min(16, (transform.physicalMagnification ?? 1) * factor))
        } else {
            transform.scale = max(1, min(64, transform.scale * factor))
        }
        if editing.actualPixels { editing.setActualPixels(false, nativeEvent: true, requestPreview: false) }
    }

    @ViewBuilder private var beforeAfterOverlay: some View {
        if editing.comparisonMode.usesWipeHandle {
            GeometryReader { geometry in
                let vertical = editing.comparisonMode == .wipeVertical
                let x = beforeAfterSplit * geometry.size.width
                let y = beforeAfterSplit * geometry.size.height
                Rectangle().fill(.white.opacity(0.82))
                    .frame(width: vertical ? geometry.size.width : 1, height: vertical ? 1 : geometry.size.height)
                    .shadow(color: .black.opacity(0.45), radius: 1)
                    .position(x: vertical ? geometry.size.width / 2 : x, y: vertical ? y : geometry.size.height / 2)
                    .allowsHitTesting(false)
                ZStack {
                    Circle().fill(AppPalette.overlay)
                    Image(systemName: vertical ? "arrow.up.and.down" : "arrow.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                }
                .frame(width: 28, height: 28).position(x: x, y: y).allowsHitTesting(false)
                Rectangle().fill(Color.clear)
                    .frame(width: vertical ? geometry.size.width : 24, height: vertical ? 24 : geometry.size.height)
                    .contentShape(Rectangle()).position(x: x, y: y)
                    .onHover { hovering in
                        if hovering { (vertical ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).set() }
                        else { NSCursor.arrow.set() }
                    }
                    .gesture(DragGesture().onChanged { value in
                        let extent = vertical ? geometry.size.height : geometry.size.width
                        guard extent > 0 else { return }
                        let location = vertical ? value.location.y : value.location.x
                        beforeAfterSplit = max(0.05, min(0.95, location / extent))
                    })
                    .accessibilityLabel("参考与当前编辑分割线")
                    .accessibilityValue("\(Int(beforeAfterSplit * 100))%")
                    .accessibilityIdentifier("editing.beforeAfter.split")
            }
        }
        if editing.comparing && !editing.comparisonMode.isSideBySide && editing.comparisonMode != .referenceOnly {
            VStack {
                Spacer()
                HStack {
                    Text(editing.comparison.inverted ? "当前编辑" : editing.comparisonReferenceTitle)
                    Spacer()
                    if editing.comparisonMode == .difference { Text("差异 · 相同显示像素为黑色") }
                    else if editing.comparisonMode == .checkerboard { Text("棋盘格") }
                    else if editing.comparisonMode == .mix {
                        let amount = editing.comparison.inverted ? 1 - beforeAfterSplit : beforeAfterSplit
                        Text("当前 \(Int(amount * 100))%")
                    }
                    Spacer()
                    Text(editing.comparison.inverted ? editing.comparisonReferenceTitle : "当前编辑")
                }
                .font(.caption.weight(.medium))
                .padding(.horizontal, EditingLayout.sidebarWidth + 36).padding(.bottom, 58)
            }
            .foregroundStyle(.white).shadow(color: .black.opacity(0.8), radius: 2).allowsHitTesting(false)
        }
        if editing.comparisonMode == .mix {
            VStack {
                Spacer()
                Slider(value: $beforeAfterSplit, in: 0...1) { Text("混合") }
                    .frame(width: 180).padding(8).background(AppPalette.overlay, in: Capsule())
                    .accessibilityLabel("当前编辑混合比例")
                    .accessibilityIdentifier("editing.beforeAfter.mix")
                    .padding(.bottom, 88)
            }
        }
    }

    private var comparisonPresentation: ImageComparisonPresentation {
        let mode: ImageComparisonMode = switch editing.comparisonMode {
        case .wipeVertical: .wipeVertical
        case .mix: .mix
        case .difference: .difference
        case .checkerboard: .checkerboard
        default: .wipeHorizontal
        }
        return .init(mode: mode, amount: beforeAfterSplit, inverted: editing.comparison.inverted)
    }

    private func imageCanvas(frame: EditingPreviewBitmap?, primary: Bool,
                             insets: NSEdgeInsets = EditingLayout.fitInsets) -> ZoomableImageView {
        var visibleSink: (@MainActor (CGRect) -> Void)?
        if primary, frame?.quality == .detail {
            visibleSink = { @MainActor [weak editing] visible in
                editing?.updateDetailVisibleWindow(visible)
            }
        }
        let hover: (@MainActor (ImageCanvasHoverEvent) -> Void)?
        if primary, !editing.comparing, editing.stage == .development, let id = frame?.id {
            hover = { [weak editing] event in
                guard let editing, let current = editing.previews.primary.frame, current.id == id else { return }
                editing.colorReadout.update(event, frame: current)
            }
        } else {
            hover = nil
        }
        return ZoomableImageView(image: nil, actualPixels: editing.actualPixels && frame?.quality == .detail, transform: $transform,
            backgroundColor: editing.darkroomBackground.nsColor,
            onActualPixelsChange: { editing.setActualPixels($0, nativeEvent: true, requestPreview: false) },
            onRequestDetail: { editing.requestDetailPreview(nativeEvent: true) }, frameID: frame?.id,
            onFrameDrawn: {
                if primary {
                    if editing.filterHoverFrame == nil && editing.sharpeningMaskPreviewFrame == nil && editing.lensBlurDepthPreviewFrame == nil { editing.previews.primary.didDraw($0, canvasDiagnostic: true) }
                } else { editing.previews.comparison.didDraw($0) }
            },
            onViewportChange: primary ? InteractionTrace.shared.initialWindowViewportSink(frameID: frame?.id, quality: frame?.quality) : nil,
            onPointerHover: hover,
            onCanvasDiagnostic: primary ? InteractionTrace.shared.canvasDiagnosticSink : nil,
            onVisibleWindow: visibleSink,
            window: frame?.window, canvasPixelSize: frame?.nativeSize)
            .borrowingImage(frame?.image)
            .lowLatency((primary && (editing.filterHoverFrame != nil || editing.sharpeningMaskPreviewFrame != nil || editing.lensBlurDepthPreviewFrame != nil)) || frame?.quality == .interactive)
            .fitting(around: insets)
    }

    private func sidePane(frame: EditingPreviewBitmap?, primary: Bool, title: String,
                          insets: NSEdgeInsets) -> some View {
        imageCanvas(frame: frame, primary: primary, insets: insets)
            .overlay(alignment: .bottom) {
                Text(title).font(.caption.weight(.medium)).foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.8), radius: 2).padding(.bottom, 58).allowsHitTesting(false)
            }
    }

    @ViewBuilder private var comparisonCanvas: some View {
        let primaryFrame = editing.lensBlurDepthPreviewFrame ?? editing.sharpeningMaskPreviewFrame ?? editing.filterHoverFrame ?? editing.previews.primary.frame
        let referenceFrame = editing.comparisonPreviewFrame
        switch editing.comparisonMode {
        case .referenceOnly:
            imageCanvas(frame: referenceFrame, primary: false)
        case .sideLeftRight, .sideTopBottom:
            let insets = NSEdgeInsets(top: EditingLayout.topInset, left: 0,
                                      bottom: EditingLayout.bottomInset, right: 0)
            let reference = sidePane(frame: referenceFrame, primary: false,
                title: editing.comparisonReferenceTitle, insets: insets)
            let current = sidePane(frame: primaryFrame, primary: true, title: "当前编辑", insets: insets)
            Group {
                if editing.comparisonMode == .sideLeftRight {
                    HStack(spacing: 1) {
                        if editing.comparison.inverted { current } else { reference }
                        if editing.comparison.inverted { reference } else { current }
                    }
                } else {
                    VStack(spacing: 1) {
                        if editing.comparison.inverted { current } else { reference }
                        if editing.comparison.inverted { reference } else { current }
                    }
                }
            }
            .padding(.horizontal, EditingLayout.sidebarWidth + EditingLayout.outerPadding * 2)
        default:
            imageCanvas(frame: primaryFrame, primary: true)
                .comparison(referenceFrame?.image, presentation: comparisonPresentation)
        }
    }

    private var currentPane: some View {
        VStack(spacing: 0) {
            ZStack {
                if let review = editing.quickPromptReview, editing.quickPromptPresented {
                    quickPromptReviewCanvas(review)
                } else if editing.quickPromptPresented {
                    imageCanvas(frame: editing.previews.primary.frame, primary: true, insets: quickPromptFitInsets).overlay {
                        if let frame = editing.previews.primary.frame {
                            GeometryReader { geometry in
                                let available = ImageViewportGeometry.imageRect(pixelSize: frame.outputSize, viewport: geometry.size,
                                    transform: transform, backingScale: backingScale, fitInsets: quickPromptFitInsets)
                                QuickPromptAreaOverlay(editing: editing, viewport: available)
                            }
                        }
                    }
                } else if editing.comparing || editing.developmentShowingOriginal {
                    comparisonCanvas
                } else if let picker = editing.developmentPicker,
                   let frame = editing.developmentPickerFrame(for: picker), let image = editing.preview {
                    PhotosDevelopmentPickerCanvas(image: image, frame: frame,
                        onFrameDrawn: { editing.previews.primary.didDraw($0) },
                        onPick: { editing.pickDevelopmentSource($0, frame: frame) },
                        onAreaPick: picker.kind == .lensBlurArea ? { start, end in editing.pickDevelopmentArea(start, end: end, frame: frame) } : nil,
                        onStrokePick: picker.kind == .lensBlurRefineFocus || picker.kind == .lensBlurRefineBlur ? { editing.pickDevelopmentLensBlurRefinement($0, frame: frame) } : nil,
                        targetedReady: editing.developmentTargetedColorReady || editing.developmentTargetedCurveReady,
                        onTargetedDrag: picker.kind.isTargetedColor ? { editing.dragDevelopmentTargetedColor($0,ended:$1) } : nil,
                        onCurveDrag: picker.kind.isTargetedCurve ? { editing.dragDevelopmentTargetedCurve($0,ended:$1) } : nil,
                        onCancel: { editing.cancelDevelopmentPicker(context: picker.context) })
                } else if editing.cropEditing && editing.stage == .development, let context = editing.developmentContext {
                    PhotosCropCanvas(editing: editing, context: context, transform: $transform).id(context)
                } else if localInput.tool != nil, editing.stage == .development, let context = editing.developmentContext {
                    PhotosLocalEditingCanvas(editing: editing, input: localInput, context: context, transform: $transform).id(context)
                } else if let owner = maskInput.canvasOwner {
                    PhotosMaskEditingCanvas(editing: editing, input: maskInput, owner: owner, transform: $transform).id(owner)
                } else {
                    comparisonCanvas
                        .overlay {
                            if !editing.comparing, editing.stage == .development, let frame = editing.previews.primary.frame,
                               let mapping = editing.presentedSamplerMapping {
                                GeometryReader { geometry in
                                    let rect = ImageViewportGeometry.imageRect(pixelSize: frame.outputSize, viewport: geometry.size,
                                        transform: transform, backingScale: backingScale, fitInsets: EditingLayout.fitInsets)
                                    PhotosColorSamplerMarkers(samplers: editing.colorSamplers, mapping: mapping, rect: rect)
                                }.allowsHitTesting(false)
                            }
                        }
                }
                beforeAfterOverlay
                if editing.quickPromptReview != nil {
                    if quickPromptDetailLoading { ProgressView("读取原尺寸边缘…").controlSize(.small) }
                } else if let error = editing.previews.primary.error {
                    VStack(spacing: 8) {
                        Text(error).font(.caption).foregroundStyle(AppPalette.warning)
                        if !editing.sourceNeedsRevalidation { Button("重试预览") { editing.retryPreview() } }
                    }.padding(20)
                } else if editing.previews.primary.rendering && editing.preview != nil {
                    VStack { HStack { Spacer(); ProgressView("计算中…").controlSize(.small).font(.caption).padding(10).background(AppPalette.overlay) }; Spacer() }
                }
                if editing.preview == nil && editing.previews.primary.error == nil {
                    if editing.loading { ProgressView("准备显影…").font(.caption) }
                    else { Text(editing.message ?? "正在渲染预览…").font(.caption).foregroundStyle(.secondary).padding(20) }
                }
                if editing.comparing && editing.comparisonPreviewFrame == nil && editing.previews.comparison.error == nil {
                    ProgressView("正在生成参考预览…").controlSize(.small).font(.caption)
                        .padding(10).background(AppPalette.overlay, in: RoundedRectangle(cornerRadius: 8))
                }
                if editing.comparing, let error = editing.previews.comparison.error {
                    Text("参考预览：" + error).font(.caption).foregroundStyle(AppPalette.warning)
                        .padding(12).background(AppPalette.overlay, in: RoundedRectangle(cornerRadius: 8))
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func quickPromptReviewCanvas(_ review: QuickPromptReview) -> some View {
        let detail = quickPromptDetail.flatMap { $0.jobID == review.job.id ? $0 : nil }
        let pixels = quickPromptShowCandidate ? (detail?.after ?? review.after) : (detail?.before ?? review.before)
        let image = NSImage(cgImage: pixels, size: NSSize(width: pixels.width, height: pixels.height))
        return ZoomableImageView(image: image, actualPixels: detail != nil, transform: $quickPromptReviewTransform,
            backgroundColor: editing.darkroomBackground.nsColor)
            .fitting(around: EditingLayout.fitInsets)
            .accessibilityLabel(quickPromptShowCandidate ? "候选" : "生成前")
            .overlay {
                if detail == nil, let snapshot = review.job.request.quickPrompt, let region = snapshot.selection {
                    GeometryReader { geometry in
                        let rect = ImageViewportGeometry.imageRect(pixelSize: CGSize(width: pixels.width, height: pixels.height),
                            viewport: geometry.size, transform: quickPromptReviewTransform, backingScale: backingScale, fitInsets: EditingLayout.fitInsets)
                        let w = rect.width / CGFloat(snapshot.basis.artifact.pixelWidth), h = rect.height / CGFloat(snapshot.basis.artifact.pixelHeight)
                        Rectangle().strokeBorder(.white.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                            .frame(width: CGFloat(region.width) * w, height: CGFloat(region.height) * h)
                            .position(x: rect.minX + (CGFloat(region.x) + CGFloat(region.width) / 2) * w,
                                      y: rect.minY + (CGFloat(region.y) + CGFloat(region.height) / 2) * h)
                    }.allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }

    private func inspectQuickPromptEdge() {
        if quickPromptDetail != nil { quickPromptDetail = nil; quickPromptReviewTransform = .init(); return }
        guard !quickPromptDetailLoading, let review = editing.quickPromptReview, let snapshot = review.job.request.quickPrompt,
              let region = snapshot.selection, let artifact = review.version.artifact,
              let url = try? editing.archive.artifactURL(artifact) else { return }
        let w = snapshot.basis.artifact.pixelWidth, h = snapshot.basis.artifact.pixelHeight
        let boxW = min(w, 850), boxH = min(h, 620)
        let crop = CGRect(x: min(w - boxW, max(0, region.x + region.width / 2 - boxW / 2)),
                          y: min(h - boxH, max(0, region.y - boxH / 2)), width: boxW, height: boxH)
        let jobID = review.job.id, basisURL = snapshot.basis.url
        quickPromptDetailLoading = true
        Task {
            defer { quickPromptDetailLoading = false }
            do {
                let detail = try await Task.detached {
                    try QuickPromptDetail(jobID: jobID, before: QuickPromptReview.crop(basisURL, to: crop),
                                          after: QuickPromptReview.crop(url, to: crop))
                }.value
                guard editing.quickPromptReview?.job.id == jobID else { return }
                quickPromptDetail = detail; quickPromptReviewTransform = .init(physicalMagnification: 1)
            } catch { editing.quickPromptNotice = "无法读取原尺寸边缘。" }
        }
    }
}
