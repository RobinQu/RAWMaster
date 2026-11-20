import AppKit
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import RAWMasterCore

struct TimelapseSheet: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var composer: TimelapseComposer
    var automaticPreview = true
    @State private var closing = false
    @State private var keyframePosition = 0.0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            heading
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 22) {
                        VStack(alignment: .leading, spacing: 8) {
                            preview.frame(height: 275)
                            Text(previewCaption).font(.caption).foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(maxWidth: .infinity)
                        primarySettings.frame(width: 230)
                    }
                    if composer.advanced { advancedSettings }
                    status
                }
            }
            Divider()
            footer
        }
        .padding(24).frame(width: 950, height: composer.advanced ? 670 : 510)
        .background(AppPalette.panel)
        .interactiveDismissDisabled(true)
        .task {
            composer.loadFirstImage()
            if automaticPreview { composer.generatePreview() }
        }
        .onChange(of: composer.settings.alignment) { _, value in
            if value != .subject { composer.stopChoosingRegion() }
        }
    }

    private var heading: some View {
        HStack(spacing: 12) {
            Image(systemName: "timelapse").font(.system(size: 28, weight: .light)).foregroundStyle(AppPalette.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text("合成延时视频").font(.title2.weight(.semibold))
                Text("\(composer.input.groupName) · \(composer.input.assets.count) 次拍摄 · \(composer.input.sourceFileCount) 个参与文件")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(composer.advanced ? "收起高级" : "高级设置") { composer.advanced.toggle() }
                .accessibilityIdentifier("timelapse.advanced")
        }
    }

    private var preview: some View {
        ZStack {
            AppPalette.thumbnailWell
            if composer.isSelectingRegion || composer.settings.alignment == .subject && composer.previewNeedsUpdate {
                if let image = composer.firstImage {
                    TimelapseRegionPicker(image: image, region: composer.settings.subjectRegion,
                        selectable: composer.isSelectingRegion, onSelect: composer.setSubjectRegion)
                } else {
                    placeholder("无法读取首帧预览", subtitle: "仍可合成视频。主体区域需先有可读取的首帧预览。")
                }
            } else if let player = composer.player {
                VideoPlayer(player: player)
            } else if let image = composer.firstImage {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                placeholder("准备延时预览", subtitle: "将按组内参与顺序合成")
            }
            if composer.isRunning {
                VStack(spacing: 9) {
                    ProgressView().controlSize(.small)
                    Text(composer.isCancelling ? "正在取消并清理…" : composer.progress?.phase.title ?? "准备合成…")
                        .font(.caption)
                }.padding(18).background(AppPalette.overlay, in: RoundedRectangle(cornerRadius: 10))
            }
        }.clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func placeholder(_ title: String, subtitle: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "play.rectangle").font(.system(size: 32, weight: .ultraLight))
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }

    private var previewCaption: String {
        if composer.isSelectingRegion { return "第一帧原图 · 拖选稳定、清晰的主体参考区域（最小边长 10%）" }
        if composer.settings.alignment == .subject && composer.previewNeedsUpdate {
            return composer.settings.subjectRegion == nil ? "第一帧原图 · 请在高级设置中选择主体参考区域" : "第一帧原图 · 已标示主体参考区域"
        }
        if composer.player != nil { return "低分辨率预览 · 帧序和节奏与导出一致，可直接播放" }
        return "\(composer.previewNeedsUpdate ? "首帧参考 · 预览尚未生成" : "预览已就绪") · 不修改原片和序列参与状态"
    }

    private var primarySettings: some View {
        VStack(alignment: .leading, spacing: 15) {
            Picker("速度", selection: $composer.settings.frameStride) {
                Text("标准 · 每张一帧").tag(1)
                Text("更快 · 每两张一帧").tag(2)
                Text("最快 · 每四张一帧").tag(4)
            }
            Picker("画幅", selection: $composer.settings.aspect) {
                ForEach(TimelapseAspect.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("成片时长").font(.caption).foregroundStyle(.secondary)
                Text(String(format: "%.1f 秒", composer.duration)).font(.system(size: 28, weight: .medium, design: .rounded)).monospacedDigit()
                Text("\(composer.outputCount) 帧 · \(composer.settings.resolution.title) · \(composer.settings.frameRate) fps")
                    .font(.caption).foregroundStyle(.secondary)
                Text("MP4 · SDR / Rec.709").font(.caption).foregroundStyle(.secondary)
            }
            Text("自动平滑光照，保留日落渐暗。画面稳定不足时会给出提示。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.disabled(composer.isRunning || closing)
    }

    private var advancedSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Picker("高级选项", selection: $composer.advancedTab) {
                ForEach(TimelapseComposer.AdvancedTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }.pickerStyle(.segmented).labelsHidden()
            Group {
                switch composer.advancedTab {
                case .light: lightSettings
                case .alignment: alignmentSettings
                case .keyframes: keyframeSettings
                case .export: exportSettings
                }
            }.frame(height: 150, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
                .disabled(composer.isRunning || closing)
        }
    }

    private var lightSettings: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("去闪烁强度").frame(width: 100, alignment: .leading)
                Slider(value: $composer.settings.deflickerStrength, in: 0...1)
                Text("\(Int((composer.settings.deflickerStrength * 100).rounded()))%").monospacedDigit().frame(width: 42)
            }
            HStack {
                Text("平滑参考半径").frame(width: 100, alignment: .leading)
                Stepper("前后各 \(composer.settings.smoothingRadius) 帧", value: $composer.settings.smoothingRadius, in: 1...60)
                Spacer()
            }
            Text("分析稳定参考区域的亮度趋势，只修正短时跳变；0% 保留原始光照。不强制统一整段亮度。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }

    private var alignmentSettings: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 22) {
                Picker("对齐方式", selection: $composer.settings.alignment) {
                    ForEach(TimelapseAlignment.allCases, id: \.self) { Text($0.title).tag($0) }
                }.frame(width: 330)
                if composer.settings.alignment == .subject {
                    Button(composer.settings.subjectRegion == nil ? "选择主体区域…" : "重选主体区域…") { composer.chooseSubjectRegion() }
                    Button("使用中央区域") { composer.setSubjectRegion(TimelapseRegion(x: 0.25, y: 0.25, width: 0.5, height: 0.5)) }
                    if composer.isSelectingRegion { Button("完成选区") { composer.stopChoosingRegion() } }
                }
            }
            HStack {
                Text("每侧最大裁切").frame(width: 100, alignment: .leading)
                Slider(value: $composer.settings.maxCropFraction, in: 0...0.2, step: 0.01)
                Text("\(Int((composer.settings.maxCropFraction * 100).rounded()))%").monospacedDigit().frame(width: 42)
            }
            Text("仅修正平移。自动稳定保留缓慢运镜；主体锚定按参考区域配准，无法处理任意透视、遮挡或三维跟踪。整段使用相同安全裁切，超限则回退并提示。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.padding(.top, 4)
    }

    private var keyframeSettings: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("第 \(Int((keyframePosition * Double(max(1, composer.input.assets.count - 1))).rounded()) + 1) 帧").monospacedDigit().frame(width: 100, alignment: .leading)
                Slider(value: $keyframePosition, in: 0...1)
                Button("添加曝光关键帧") { composer.addKeyframe(at: keyframePosition) }
                    .disabled(composer.settings.keyframes.count >= 32)
            }
            if composer.settings.keyframes.isEmpty {
                Text("选择帧位置后添加关键帧，调整曝光补偿；帧间平滑过渡。原片不变。")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 10)
            } else {
                ScrollView {
                    VStack(spacing: 5) {
                        ForEach(Array(composer.settings.keyframes.enumerated()), id: \.element.id) { index, key in
                            HStack(spacing: 12) {
                                Text("第 \(Int((key.position * Double(max(1, composer.input.assets.count - 1))).rounded()) + 1) 帧").monospacedDigit().frame(width: 100, alignment: .leading)
                                Slider(value: keyframeExposure(index), in: -4...4, step: 0.1)
                                Text(String(format: "%+.1f EV", key.exposureEV)).monospacedDigit().frame(width: 75)
                                Button { composer.settings.keyframes.remove(at: index) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("删除关键帧")
                            }
                        }
                    }
                }
            }
        }.padding(.top, 4)
    }
    private func keyframeExposure(_ index: Int) -> Binding<Double> {
        Binding(get: { composer.settings.keyframes.indices.contains(index) ? composer.settings.keyframes[index].exposureEV : 0 },
            set: { if composer.settings.keyframes.indices.contains(index) { composer.settings.keyframes[index].exposureEV = $0 } })
    }

    private var exportSettings: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 24) {
                Picker("分辨率", selection: $composer.settings.resolution) {
                    ForEach(TimelapseResolution.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Picker("帧率", selection: $composer.settings.frameRate) {
                    ForEach([24, 25, 30], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Picker("编码", selection: $composer.settings.codec) {
                    ForEach(TimelapseCodec.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            Text("导出独立 MP4。每张参与照片需要可读取；遇到缺片或解码错误会停止，不会悄悄跳过。已有文件不会被覆盖。")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.top, 4)
    }

    @ViewBuilder private var status: some View {
        if let progress = composer.progress, composer.isRunning {
            HStack {
                ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total))).frame(maxWidth: .infinity)
                Text("\(progress.completed) / \(progress.total)").font(.caption.monospacedDigit()).frame(width: 95, alignment: .trailing)
            }
        }
        if let message = composer.errorMessage ?? composer.validationMessage {
            Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(AppPalette.warning).font(.caption)
                .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("timelapse.error")
        }
        if !composer.warnings.isEmpty {
            Text(composer.warnings.joined(separator: "\n")).font(.caption).foregroundStyle(AppPalette.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let output = composer.exportedURL {
            HStack {
                Label("视频已导出：\(output.lastPathComponent)", systemImage: "checkmark.circle").font(.caption).lineLimit(1)
                Button("在 Finder 中显示") { model.reveal(output.path) }.controlSize(.small)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Button(closing ? "正在关闭…" : "关闭") {
                closing = true
                Task { await model.closeTimelapse() }
            }.keyboardShortcut(.cancelAction).disabled(closing)
            if composer.isRunning {
                Button(composer.isCancelling ? "正在取消…" : "取消合成") { composer.cancel() }.disabled(composer.isCancelling || closing)
            }
            Spacer()
            Button(composer.previewNeedsUpdate ? "生成预览" : "重新生成预览") { composer.generatePreview() }
                .disabled(!composer.canRender || closing).accessibilityIdentifier("timelapse.preview")
            Button("导出视频…") { chooseOutput() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!composer.canRender || closing).accessibilityIdentifier("timelapse.export")
        }
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.title = "导出延时视频"; panel.allowedContentTypes = [.mpeg4Movie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = composer.input.groupName.replacingOccurrences(of: "/", with: "-") + ".mp4"
        panel.message = "生成独立 MP4，请选择新文件名；不会覆盖已有文件。"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        composer.export(to: output)
    }
}

/// Map a drag in an aspect-fit source view to normalized, bottom-left image coordinates.
enum TimelapseRegionGeometry {
    static func fittedRect(imageSize: CGSize, container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, container.width > 0, container.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
    }
    static func region(start: CGPoint, end: CGPoint, imageRect: CGRect) -> TimelapseRegion? {
        guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(start) else { return nil }
        let x0 = max(imageRect.minX, min(start.x, end.x)), x1 = min(imageRect.maxX, max(start.x, end.x))
        let y0 = max(imageRect.minY, min(start.y, end.y)), y1 = min(imageRect.maxY, max(start.y, end.y))
        let width = (x1 - x0) / imageRect.width, height = (y1 - y0) / imageRect.height
        let region = TimelapseRegion(x: (x0 - imageRect.minX) / imageRect.width,
            y: 1 - (y1 - imageRect.minY) / imageRect.height, width: width, height: height)
        return region.isValid ? region : nil
    }
    static func rect(_ region: TimelapseRegion, in imageRect: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + region.x * imageRect.width,
            y: imageRect.minY + (1 - region.y - region.height) * imageRect.height,
            width: region.width * imageRect.width, height: region.height * imageRect.height)
    }
}

private struct TimelapseRegionPicker: View {
    let image: NSImage
    let region: TimelapseRegion?
    let selectable: Bool
    let onSelect: (TimelapseRegion) -> Void
    @State private var drag: (CGPoint, CGPoint)?
    var body: some View {
        GeometryReader { proxy in
            let imageRect = TimelapseRegionGeometry.fittedRect(imageSize: image.size, container: proxy.size)
            ZStack(alignment: .topLeading) {
                Image(nsImage: image).resizable().scaledToFit().frame(width: proxy.size.width, height: proxy.size.height)
                if let selection = drag.flatMap({ TimelapseRegionGeometry.region(start: $0.0, end: $0.1, imageRect: imageRect) }) ?? region {
                    let r = TimelapseRegionGeometry.rect(selection, in: imageRect)
                    Rectangle().fill(AppPalette.accent.opacity(0.12)).border(AppPalette.accent, width: 2)
                        .frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY)
                }
                if selectable {
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 3).onChanged { value in drag = (value.startLocation, value.location) }
                            .onEnded { value in
                                if let selected = TimelapseRegionGeometry.region(start: value.startLocation, end: value.location, imageRect: imageRect) { onSelect(selected) }
                                drag = nil
                            })
                        .accessibilityLabel("拖动选择主体参考区域")
                }
            }
        }
    }
}
