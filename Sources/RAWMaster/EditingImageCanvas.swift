import AppKit
import SwiftUI
import RAWMasterCore
import RAWMasterImaging

struct EditingImageCanvas: View {
    @ObservedObject var editing: EditingController
    @ObservedObject var localInput: EditingLocalInputSession
    @State private var transform = ImageTransform()
    @State private var showBaseline = false
    private struct PickerPresentationSnapshot {
        let context: EditingInteractionContext
        let transform: ImageTransform
        let actualPixels: Bool
    }
    @State private var pickerPresentationSnapshot: PickerPresentationSnapshot?
    init(editing: EditingController) { self.editing = editing; self.localInput = editing.developmentLocalInput }
    var body: some View {
        ZStack {
            if editing.comparing, let baseline = editing.versions.first(where: { $0.id == editing.comparisonVersionID }) {
                GeometryReader { geometry in
                    if geometry.size.width >= 700 {
                        HStack(spacing: 1) {
                            EditingVersionPane(editing: editing, version: baseline, transform: $transform, title: "比较基准")
                            currentPane
                        }
                    } else {
                        VStack(spacing: 0) {
                            Picker("版本比较", selection: $showBaseline) { Text("比较基准").tag(true); Text("查看版本").tag(false) }
                                .pickerStyle(.segmented).padding(10).frame(maxWidth: 330)
                            if showBaseline { EditingVersionPane(editing: editing, version: baseline, transform: $transform, title: "比较基准") }
                            else { currentPane }
                        }
                    }
                }
            } else { currentPane }
        }
        .background(AppPalette.canvas)
        .overlay(alignment: .bottom) { canvasControls.padding(.bottom, 52) }
        .onChange(of: editing.selectedVersionID) { _, _ in transform = ImageTransform() }
        .onChange(of: editing.comparing) { _, _ in editing.requestPreview() }
        .onChange(of: editing.comparisonVersionID) { _, _ in if editing.comparing { editing.requestPreview() } }
        .onChange(of: editing.developmentContext) { _, context in
            transform = ImageTransform()
            if pickerPresentationSnapshot?.context != context { pickerPresentationSnapshot = nil }
        }
        .onChange(of: editing.developmentPicker?.id) { _, pickerID in
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
        HStack(spacing: 10) {
            if editing.stage == .development, let context = editing.developmentContext,
               editing.supportsDevelopmentAutomatic(.light), editing.supportsDevelopmentAutomatic(.color) {
                Button { editing.requestDevelopmentAutomatic(nil, context: context, nativeEvent: true) } label: {
                    Image(systemName: "wand.and.stars").frame(width: 26, height: 26)
                }
                .help("自动增强").accessibilityLabel("自动增强").accessibilityIdentifier("photos.autoEnhance")
            }
            if editing.comparing {
                Picker("比较基准", selection: $editing.comparisonVersionID) {
                    ForEach(editing.versions) { version in
                        Text((version.id == editing.work?.adoptedVersionID ? "当前采用 · " : "") + version.editingTitle + " " + version.shortID).tag(Optional(version.id))
                    }
                }.frame(maxWidth: 210)
                Button { editing.comparing = false } label: { Image(systemName: "xmark").frame(width: 26, height: 26) }
                    .help("结束版本比较")
            } else {
                Button { editing.comparing = true } label: {
                    Image(systemName: "rectangle.split.2x1").frame(width: 26, height: 26)
                }
                .disabled(editing.stage == .development && editing.isDirty)
                .help("比较已保存版本").accessibilityLabel("比较版本").accessibilityIdentifier("editing.compare")
            }
            Divider().frame(height: 18)
            Button {
                editing.setActualPixels(!editing.actualPixels, nativeEvent: true)
                if !editing.actualPixels { transform = ImageTransform() }
            } label: {
                Label(editing.actualPixels ? "适合" : "100%", systemImage: editing.actualPixels ? "arrow.down.right.and.arrow.up.left" : "1.magnifyingglass")
                    .frame(minHeight: 26)
            }
            .disabled((editing.cropEditing && editing.stage == .development) || editing.developmentPicker != nil)
            .help(editing.actualPixels ? "适合窗口 · Z" : "实际像素 · Z")
            .accessibilityIdentifier("editing.actualPixels")
            if editing.stage == .development {
                Button { editing.setDevelopmentOriginalHeld(!editing.developmentShowingOriginal) } label: {
                    Image(systemName: editing.developmentShowingOriginal ? "photo.fill" : "photo")
                        .frame(width: 26, height: 26)
                }
                .help("按住 M 查看原片")
                .accessibilityLabel(editing.developmentShowingOriginal ? "显示调整后照片" : "显示原片")
            }
        }
        .buttonStyle(.plain)
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 7)
        .floatingSelectionSurface()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("照片查看工具")
    }
    private var currentPane: some View {
        VStack(spacing: 0) {
            ZStack {
                if let picker = editing.developmentPicker,
                   let frame = editing.developmentPickerFrame(for: picker), let image = editing.preview {
                    PhotosDevelopmentPickerCanvas(image: image, frame: frame,
                        onFrameDrawn: { editing.previews.primary.didDraw($0) },
                        onPick: { editing.pickDevelopmentSource($0, frame: frame) },
                        onCancel: { editing.cancelDevelopmentPicker(context: picker.context) })
                } else if editing.cropEditing && editing.stage == .development, let context = editing.developmentContext {
                    PhotosCropCanvas(editing: editing, context: context, transform: $transform).id(context)
                } else if localInput.tool != nil, editing.stage == .development, let context = editing.developmentContext {
                    PhotosLocalEditingCanvas(editing: editing, input: localInput, context: context, transform: $transform).id(context)
                } else {
                    // Bind image, ID and quality to the same coordinator-owned frame.
                    let frame = editing.previews.primary.frame
                    ZoomableImageView(image: nil, actualPixels: editing.actualPixels && frame?.quality == .detail, transform: $transform,
                        backgroundColor: AppPalette.canvasNSColor, onActualPixelsChange: { editing.setActualPixels($0, nativeEvent: true) },
                        onRequestDetail: { editing.setActualPixels(true, nativeEvent: true) }, frameID: frame?.id,
                        onFrameDrawn: { editing.previews.primary.didDraw($0, canvasDiagnostic: true) },
                        onViewportChange: InteractionTrace.shared.initialWindowViewportSink(frameID: frame?.id, quality: frame?.quality),
                        onCanvasDiagnostic: InteractionTrace.shared.canvasDiagnosticSink)
                        .borrowingImage(frame?.image)
                }
                if let error = editing.previews.primary.error {
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
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack {
                Text(editing.canvasTitle).font(.caption).lineLimit(1)
                Spacer(minLength: 4)
                Text(editing.previewDimensions).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }.padding(.horizontal, 12).padding(.vertical, 8).background(AppPalette.overlay)
        }
    }
}

private struct EditingVersionPane: View {
    @ObservedObject var editing: EditingController
    let version: EditingVersion
    @Binding var transform: ImageTransform
    let title: String
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ZoomableImageView(image: editing.previews.comparison.frame?.image,
                    actualPixels: editing.actualPixels && editing.previews.comparison.frame?.quality == .detail,
                    transform: $transform, backgroundColor: AppPalette.canvasNSColor,
                    onActualPixelsChange: { editing.setActualPixels($0, nativeEvent: true) }, onRequestDetail: { editing.setActualPixels(true, nativeEvent: true) },
                    frameID: editing.previews.comparison.frame?.id, onFrameDrawn: { editing.previews.comparison.didDraw($0) })
                if let error = editing.previews.comparison.error { Text(error).font(.caption).foregroundStyle(AppPalette.warning).padding(20) }
                else if editing.previews.comparison.frame == nil { ProgressView().controlSize(.small) }
                else if editing.previews.comparison.rendering { VStack { HStack { Spacer(); ProgressView().controlSize(.small).padding(10) }; Spacer() } }
            }
            Text(title + " · " + version.editingTitle + " · " + version.shortID).font(.caption).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8).background(AppPalette.overlay)
        }
    }
}

